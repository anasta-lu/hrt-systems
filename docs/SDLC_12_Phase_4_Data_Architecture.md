# Phase 4: Data Architecture (The Accounting Kernel)

This document translates the HRT Systems Master Context and the Phase 3B Event Matrix into a physical PostgreSQL database schema. 

The core architectural invariant is the strict separation between what happened (Business Event), how it is interpreted (Accounting Event), and where it is posted (Ledger Entry).

## 1. The Event Sourcing Foundation
All financial movements begin with an immutable business event. This table tracks the operational reality.

```sql
CREATE TABLE business_events (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    entity_id UUID NOT NULL,
    event_type VARCHAR(100) NOT NULL, -- e.g., 'CustomerInvoiceIssued'
    source_object_type VARCHAR(100), -- e.g., 'CustomerInvoice'
    source_object_id UUID,
    occurred_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    actor_id UUID, -- Who triggered it
    correlation_id UUID, -- For tracking API/Temporal chains
    idempotency_key VARCHAR(255) UNIQUE,
    evidence_reference VARCHAR(500), -- Link to PDF/Hash
    status VARCHAR(50) DEFAULT 'PENDING_ACCOUNTING'
);
```

## 2. The Accounting Event Contract
As mandated by the Master Context, this is the core interpreter. When a `business_event` fires, the rules engine generates an `accounting_event`. This table stores the exact state of the world (rates, rules, dates) at the moment of interpretation.

```sql
CREATE TABLE accounting_events (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    source_event_id UUID REFERENCES business_events(id),
    
    -- Organizational Routing
    entity_id UUID NOT NULL,
    ledger_id UUID NOT NULL,
    accounting_framework_id UUID, -- e.g., 'AASB', 'IFRS'
    
    -- Crucial Dates
    economic_date DATE NOT NULL,
    accounting_date DATE NOT NULL,
    tax_date DATE,
    accounting_period_id UUID NOT NULL,
    
    -- Multi-Currency & FX
    currency_code VARCHAR(3) NOT NULL,
    exchange_rate DECIMAL(19,6) DEFAULT 1.0,
    exchange_rate_type VARCHAR(50), -- e.g., 'SPOT', 'AVERAGE'
    exchange_rate_date DATE,
    
    -- Rule Versioning (Immutability)
    accounting_rule_id VARCHAR(100),
    accounting_rule_version INTEGER NOT NULL,
    tax_treatment VARCHAR(100),
    
    -- Dimensionality
    dimension_set_id UUID, -- Maps to the Dynamic EAV Dimension tables
    
    -- Amounts
    source_amount DECIMAL(19,4) NOT NULL,
    functional_amount DECIMAL(19,4) NOT NULL,
    reporting_amount DECIMAL(19,4),
    
    status VARCHAR(50) DEFAULT 'POSTED',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
```

## 3. The General Ledger (GL) Entries
The `accounting_event` then generates the actual Debits and Credits in the GL. This table must be incredibly fast to query for Trial Balances.

```sql
CREATE TABLE ledger_entries (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    accounting_event_id UUID REFERENCES accounting_events(id) ON DELETE RESTRICT,
    account_id UUID NOT NULL, -- The Thin Natural Account (e.g., 4000-Sales)
    
    -- We use a signed amount (+ for Debit, - for Credit) for faster SUM() aggregations, 
    -- but store the explicit DR/CR flag for traditional reporting.
    amount DECIMAL(19,4) NOT NULL, 
    entry_type VARCHAR(2) CHECK (entry_type IN ('DR', 'CR')),
    
    -- The specific dimensions for this line
    dimension_set_id UUID,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexing for hyper-fast Trial Balance generation
CREATE INDEX idx_ledger_tb ON ledger_entries (tenant_id, account_id, dimension_set_id);
```

## 4. Accounting Periods & Close Controls
To enforce the `AccountingPeriodClosed` event, the database must strictly validate the period state before allowing any `ledger_entries` to be written.

```sql
CREATE TABLE accounting_periods (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    entity_id UUID NOT NULL,
    calendar_id UUID NOT NULL,
    period_name VARCHAR(50), -- e.g., '2026-Oct'
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    
    -- The Master Switch
    status VARCHAR(50) CHECK (status IN ('OPEN', 'CLOSED', 'REOPENED', 'PENDING_CLOSE')),
    
    -- Module-Specific Control Gates
    ap_ready_status VARCHAR(50) DEFAULT 'NOT_RUN',
    ar_ready_status VARCHAR(50) DEFAULT 'NOT_RUN',
    bank_ready_status VARCHAR(50) DEFAULT 'NOT_RUN',
    tax_ready_status VARCHAR(50) DEFAULT 'NOT_RUN',
    inventory_ready_status VARCHAR(50) DEFAULT 'NOT_RUN',
    
    closed_at TIMESTAMP WITH TIME ZONE,
    closed_by UUID
);
```

## 5. Architectural Safeguards (The "Immutability" Guarantee)
To fulfill the requirement: *"Never silently overwrite financial history."*

1. **No Cascading Deletes:** The schema uses `ON DELETE RESTRICT` for all financial data. You cannot delete an `accounting_event` if a `ledger_entry` exists.
2. **Versioned Rules:** By storing `accounting_rule_version` directly on the `accounting_event`, if the CFO changes the revenue recognition policy in 2027, the 2026 transactions will permanently retain and prove they used version 1 of the rule.
3. **Optimistic Concurrency:** The application layer (FastAPI) will utilize `lock_version` integers on mutable records (like Invoices), while the database will use `FOR UPDATE` row-level locks during the split-second `ledger_entry` posting process to prevent race conditions.

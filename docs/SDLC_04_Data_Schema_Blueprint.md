# SDLC Phase 4: Data Schema Blueprint (Core Ledger)

## 1. The Dynamic Dimensional Architecture
To allow businesses to define their own core dimensions (e.g., naming them "Region" instead of "Location", or adding 10 dimensions instead of 3), the database uses a strict Relational Mapping structure. This enforces Foreign Key validation without hardcoding columns.

### 1.1. Dimension Definitions (Configurable per Tenant)
This table allows the business to define what dimensions exist for their specific instance.
```sql
CREATE TABLE dimensions (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    name VARCHAR(100), -- e.g., "Region", "Project", "Grant"
    is_active BOOLEAN DEFAULT TRUE,
    is_mandatory_on_header BOOLEAN DEFAULT FALSE,
    is_mandatory_on_lines BOOLEAN DEFAULT FALSE
);

CREATE TABLE dimension_values (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    dimension_id UUID REFERENCES dimensions(id),
    code VARCHAR(50), -- e.g., "NA", "PRJ-01"
    name VARCHAR(100) -- e.g., "North America", "Website Build"
);
```

### 1.2. Transaction Headers (e.g., Invoices, Journals)
Header-level tagging applies default dimensions to the entire document.
```sql
CREATE TABLE journals (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    journal_date DATE NOT NULL,
    reference VARCHAR(255),
    status VARCHAR(50) -- DRAFT, POSTED
);

CREATE TABLE journal_header_dimensions (
    journal_id UUID REFERENCES journals(id),
    dimension_id UUID REFERENCES dimensions(id),
    dimension_value_id UUID REFERENCES dimension_values(id),
    PRIMARY KEY (journal_id, dimension_id)
);
```

### 1.3. Line Item Tagging (Subledger / Journal Lines)
Line-level tagging overrides the header to split expenses across multiple cost centers.
```sql
CREATE TABLE journal_lines (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    journal_id UUID REFERENCES journals(id),
    account_id UUID REFERENCES accounts(id), -- The Thin Natural Account
    description VARCHAR(255),
    -- Multi-Currency Columns
    foreign_amount DECIMAL(19,4),
    foreign_currency_code VARCHAR(3),
    base_amount DECIMAL(19,4),
    exchange_rate DECIMAL(19,6)
);

-- The strict Foreign Key mapping table for line items
CREATE TABLE journal_line_dimensions (
    journal_line_id UUID REFERENCES journal_lines(id),
    dimension_id UUID REFERENCES dimensions(id),
    dimension_value_id UUID REFERENCES dimension_values(id),
    PRIMARY KEY (journal_line_id, dimension_id)
);
```

## 2. Multi-Currency Rules (AASB 121 Compliance)
Every single journal line records the exact foreign amount and the exchange rate used at the exact moment of the transaction.
- If an invoice is generated for $1,000 USD (Base: AUD), the AP subledger line holds the USD and AUD amounts.
- At Month-End, the Temporal.io worker scans all unpaid foreign lines. It generates a temporary `Journal` recording the Unrealized FX Gain/Loss based on the month-end spot rate.
- Upon payment, a final `Journal` is posted mapping the Realized FX Gain/Loss.

## 3. The "Account Validation" Rules Engine
To enforce rules (e.g., "Travel Expense requires a Department dimension"), a validation table links Natural Accounts to mandatory dimensions.
```sql
CREATE TABLE account_dimension_rules (
    account_id UUID REFERENCES accounts(id),
    dimension_id UUID REFERENCES dimensions(id),
    is_required BOOLEAN DEFAULT TRUE,
    PRIMARY KEY (account_id, dimension_id)
);
```

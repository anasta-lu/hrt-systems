-- =============================================================================
-- FILE:    005_revenue_close_consolidation.sql
-- SYSTEM:  HRT Systems (Radical TG) - Database Design v2 Migration 005
-- PURPOSE: Implements the advanced financial and group architectures:
--          1. AASB 15 / IFRS 15 5-Step Revenue Recognition Engine (Domain 13)
--          2. Multi-Entity Intercompany Mirroring & Reconciliation (Domain 16)
--          3. Group Financial Consolidation & Unrealized Profit Elimination (Domain 16)
--          4. Continuous Period Close Workspace & Audit Portal PBC (Domain 17 & 19)
--          5. High-Availability Ingress Buffer & Dead-Letter Replay (Domain 20)
--
-- DESIGN RATIONALE:
--   * Master Context Sections 221-227 (Revenue), 236-241 (Intercompany/Consolidation),
--     242-254 (Close/Audit), 97-104 (Integrations)
--   * SDLC_22 Architectural Rectification & SDLC_23 Complete Data Architecture
--   * AASB 15 Separation: Billing != Revenue != Cash
--   * Elimination Invariant: Eliminating internal margin requires Dr Group COGS, Cr Inventory
-- =============================================================================


-- =============================================================================
-- SECTION 1. REVENUE RECOGNITION ENGINE (DOMAIN 13 - AASB 15 / IFRS 15)
-- Deterministic 5-step model separating invoicing from revenue recognition.
-- =============================================================================

-- Step 1: Customer Contracts with Commercial Substance
CREATE TABLE revenue_contracts (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    customer_party_id    uuid          NOT NULL REFERENCES parties(id),
    contract_number      varchar(100)  NOT NULL,
    contract_date        date          NOT NULL,
    start_date           date          NOT NULL,
    end_date             date,
    total_contract_value numeric(19,4) NOT NULL CHECK (total_contract_value >= 0),
    currency_code        char(3)       NOT NULL REFERENCES currencies(code),
    status               varchar(20)   NOT NULL DEFAULT 'ACTIVE'
                         CHECK (status IN ('DRAFT','ACTIVE','MODIFIED','COMPLETED','TERMINATED')),
    created_at           timestamptz   NOT NULL DEFAULT now(),
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, contract_number)
);

-- Step 2: Performance Obligations (Distinct Goods / Services)
CREATE TABLE performance_obligations (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id          uuid          NOT NULL REFERENCES revenue_contracts(id) ON DELETE CASCADE,
    obligation_number    varchar(50)   NOT NULL,
    description          varchar(500)  NOT NULL,
    recognition_pattern  varchar(30)   NOT NULL
                         CHECK (recognition_pattern IN ('POINT_IN_TIME','OVER_TIME_INPUT','OVER_TIME_OUTPUT','STRAIGHT_LINE')),
    contract_asset_acct_id uuid        NOT NULL REFERENCES accounts(id), -- Account 1400 Contract Asset / WIP
    contract_liab_acct_id  uuid        NOT NULL REFERENCES accounts(id), -- Account 2400 Contract Liability
    revenue_account_id     uuid        NOT NULL REFERENCES accounts(id), -- Account 4100 Sales Revenue
    stand_alone_sell_price numeric(19,4) NOT NULL CHECK (stand_alone_sell_price >= 0), -- Step 4 SSP
    allocated_amount     numeric(19,4) NOT NULL DEFAULT 0 CHECK (allocated_amount >= 0),
    is_satisfied         boolean       NOT NULL DEFAULT false,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (contract_id, obligation_number)
);

-- Step 5: Revenue Release Schedules & Milestone Tracking
CREATE TABLE revenue_schedules (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    obligation_id        uuid          NOT NULL REFERENCES performance_obligations(id) ON DELETE CASCADE,
    accounting_period_id uuid          NOT NULL REFERENCES accounting_periods(id),
    schedule_date        date          NOT NULL,
    planned_amount       numeric(19,4) NOT NULL CHECK (planned_amount >= 0),
    recognised_amount    numeric(19,4) NOT NULL DEFAULT 0 CHECK (recognised_amount >= 0),
    is_fully_recognised  boolean       GENERATED ALWAYS AS (recognised_amount >= planned_amount) STORED,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (obligation_id, accounting_period_id)
);

-- Executed Revenue Events (Dr Contract Liability / Dr Contract Asset, Cr Revenue)
CREATE TABLE revenue_recognition_runs (
    id                 uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id          uuid          NOT NULL REFERENCES entities(id),
    obligation_id      uuid          NOT NULL REFERENCES performance_obligations(id),
    business_event_id  uuid          NOT NULL REFERENCES business_events(id),
    schedule_id        uuid          REFERENCES revenue_schedules(id),
    amount_recognised  numeric(19,4) NOT NULL CHECK (amount_recognised > 0),
    recognised_at      timestamptz   NOT NULL DEFAULT now(),
    created_at         timestamptz   NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 2. INTERCOMPANY & GROUP CONSOLIDATION (DOMAIN 16)
-- Multi-entity mirroring, reconciliation, and elimination of unrealized profit.
-- =============================================================================

-- Intercompany Trading Agreements between Group Entities
CREATE TABLE intercompany_agreements (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    origin_entity_id     uuid          NOT NULL REFERENCES entities(id),
    counterparty_entity_id uuid        NOT NULL REFERENCES entities(id),
    agreement_code       varchar(50)   NOT NULL UNIQUE,
    settlement_currency  char(3)       NOT NULL REFERENCES currencies(code),
    transfer_pricing_rule varchar(50)  NOT NULL, -- 'COST_PLUS_10', 'MARKET_RATE'
    is_active            boolean       NOT NULL DEFAULT true,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    CHECK (origin_entity_id <> counterparty_entity_id)
);

-- Intercompany Transaction Pair (Tracks mirror invoicing)
CREATE TABLE intercompany_transactions (
    id                     uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    agreement_id           uuid          NOT NULL REFERENCES intercompany_agreements(id),
    origin_entity_id       uuid          NOT NULL REFERENCES entities(id),
    counterparty_entity_id uuid          NOT NULL REFERENCES entities(id),
    origin_invoice_id      uuid          REFERENCES customer_invoices(id),
    mirror_bill_id         uuid          REFERENCES supplier_invoices(id),
    amount                 numeric(19,4) NOT NULL,
    currency_code          char(3)       NOT NULL REFERENCES currencies(code),
    match_status           varchar(20)   NOT NULL DEFAULT 'UNMATCHED'
                           CHECK (match_status IN ('UNMATCHED','MATCHED','DISPUTED','SETTLED')),
    created_at             timestamptz   NOT NULL DEFAULT now()
);

-- Formal Consolidation Execution Runs
CREATE TABLE consolidation_runs (
    id                     uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id               uuid          NOT NULL REFERENCES consolidation_groups(id),
    accounting_period_id   uuid          NOT NULL REFERENCES accounting_periods(id),
    run_date               date          NOT NULL,
    status                 varchar(20)   NOT NULL DEFAULT 'IN_PROGRESS'
                           CHECK (status IN ('IN_PROGRESS','VALIDATED','FINAL_POSTED')),
    executed_by            uuid          REFERENCES users(id),
    executed_at            timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (group_id, accounting_period_id)
);

-- Elimination Journals (AASB 10 / AASB 128)
-- Implements proper inventory markup elimination: Dr Group COGS, Cr Inventory
CREATE TABLE consolidation_elimination_entries (
    id                     uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    consolidation_run_id   uuid          NOT NULL REFERENCES consolidation_runs(id) ON DELETE CASCADE,
    elimination_type       varchar(30)   NOT NULL
                           CHECK (elimination_type IN ('INTERCOMPANY_BALANCE','INTERCOMPANY_REVENUE_COGS','UNREALIZED_PROFIT_INVENTORY','DIVIDEND_ELIMINATION')),
    origin_entity_id       uuid          NOT NULL REFERENCES entities(id),
    counterparty_entity_id uuid          NOT NULL REFERENCES entities(id),
    debit_account_id       uuid          NOT NULL REFERENCES accounts(id),
    credit_account_id      uuid          NOT NULL REFERENCES accounts(id),
    elimination_amount     numeric(19,4) NOT NULL CHECK (elimination_amount > 0),
    reporting_currency     char(3)       NOT NULL REFERENCES currencies(code),
    description            varchar(500)  NOT NULL,
    created_at             timestamptz   NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 3. PERIOD CLOSE WORKSPACE & RECONCILIATIONS (DOMAIN 17)
-- Continuous close workspace tracking subledger reconciliation variances.
-- =============================================================================

CREATE TABLE close_workspaces (
    id                   uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid         NOT NULL REFERENCES entities(id),
    accounting_period_id uuid         NOT NULL REFERENCES accounting_periods(id),
    status               varchar(20)  NOT NULL DEFAULT 'OPEN'
                         CHECK (status IN ('OPEN','IN_REVIEW','READY_FOR_CLOSE','CLOSED')),
    notes                text,
    created_at           timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (entity_id, accounting_period_id)
);

-- Automated Subledger to Control Account Reconciliation Balances
CREATE TABLE subledger_reconciliations (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id         uuid          NOT NULL REFERENCES close_workspaces(id) ON DELETE CASCADE,
    subledger_code       varchar(30)   NOT NULL
                         CHECK (subledger_code IN ('AP','AR','BANK','INVENTORY','FIXED_ASSETS','TAX','PAYROLL','REVENUE')),
    gl_control_account_id uuid         NOT NULL REFERENCES accounts(id),
    gl_balance           numeric(19,4) NOT NULL,
    subledger_balance    numeric(19,4) NOT NULL,
    variance             numeric(19,4) GENERATED ALWAYS AS (gl_balance - subledger_balance) STORED,
    status               varchar(20)   NOT NULL DEFAULT 'UNRECONCILED'
                         CHECK (status IN ('UNRECONCILED','BALANCED','VARIANCE_EXPLAINED','APPROVED')),
    reconciled_by        uuid          REFERENCES users(id),
    reconciled_at        timestamptz,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, subledger_code)
);


-- =============================================================================
-- SECTION 4. EVIDENCE, PROVENANCE & AUDIT PORTAL (DOMAIN 19)
-- PBC (Provided by Client) ticket management for external auditors.
-- =============================================================================

CREATE TABLE auditor_portal_requests (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    accounting_period_id uuid          NOT NULL REFERENCES accounting_periods(id),
    request_number       varchar(50)   NOT NULL,
    title                varchar(200)  NOT NULL,
    requested_by_auditor varchar(200)  NOT NULL,
    status               varchar(20)   NOT NULL DEFAULT 'OPEN'
                         CHECK (status IN ('OPEN','IN_PROGRESS','SUBMITTED','ACCEPTED')),
    due_date             date,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, request_number)
);

CREATE TABLE auditor_portal_items (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id           uuid          NOT NULL REFERENCES auditor_portal_requests(id) ON DELETE CASCADE,
    business_event_id    uuid          REFERENCES business_events(id),
    evidence_file_id     uuid          REFERENCES evidence_files(id),
    auditor_comments     varchar(1000),
    client_response      varchar(1000),
    is_verified          boolean       NOT NULL DEFAULT false,
    created_at           timestamptz   NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 5. INTEGRATION INGRESS & DEAD-LETTER QUEUE (DOMAIN 20)
-- Fault-tolerant perimeter for webhooks (HubSpot, Monday, Asana, ServiceM8).
-- =============================================================================

-- Ingress buffer: FastAPI stores raw webhooks before durable Temporal execution
CREATE TABLE inbox_events (
    id                 uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    source_system      varchar(50)  NOT NULL, -- 'HubSpot', 'Salesforce', 'Monday'
    external_event_id  varchar(255) NOT NULL,
    payload            jsonb        NOT NULL,
    status             varchar(20)  NOT NULL DEFAULT 'RECEIVED'
                       CHECK (status IN ('RECEIVED','PROCESSING','PROCESSED','FAILED')),
    received_at        timestamptz  NOT NULL DEFAULT now(),
    processed_at       timestamptz,
    UNIQUE (source_system, external_event_id)
);

-- External System ID Mapping (e.g. Asana Project ID -> AX Project UUID)
CREATE TABLE external_system_mappings (
    id                 uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    source_system      varchar(50)  NOT NULL,
    external_id        varchar(255) NOT NULL,
    object_type        varchar(50)  NOT NULL, -- 'Customer', 'Project', 'Invoice'
    internal_id        uuid         NOT NULL,
    created_at         timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (source_system, object_type, external_id)
);

-- Dead-Letter Queue: failed events requiring human correction/mapping
CREATE TABLE integration_dead_letters (
    id                 uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    inbox_event_id     uuid         REFERENCES inbox_events(id),
    error_code         varchar(50)  NOT NULL,
    error_message      varchar(2000) NOT NULL,
    retry_count        integer      NOT NULL DEFAULT 0,
    is_resolved        boolean      NOT NULL DEFAULT false,
    resolved_by        uuid         REFERENCES users(id),
    resolved_at        timestamptz,
    created_at         timestamptz  NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 6. TRIGGER WIRING & IMMUTABILITY ENFORCEMENT
-- =============================================================================

-- Immutability on executed revenue runs and elimination journals
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'revenue_recognition_runs', 'consolidation_elimination_entries',
        'auditor_portal_items']
    LOOP
        EXECUTE format('CREATE TRIGGER t_%s_immutable BEFORE UPDATE OR DELETE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_reject_mutation()', t, t);
        EXECUTE format('CREATE TRIGGER t_%s_no_truncate BEFORE TRUNCATE ON %I
                        FOR EACH STATEMENT EXECUTE FUNCTION trg_reject_mutation()', t, t);
    END LOOP;
END $$;

-- Audit logging on configuration & workspaces
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'revenue_contracts', 'performance_obligations', 'intercompany_agreements',
        'consolidation_runs', 'close_workspaces', 'subledger_reconciliations',
        'auditor_portal_requests']
    LOOP
        EXECUTE format('CREATE TRIGGER t_%s_audit AFTER INSERT OR UPDATE OR DELETE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_audit_row()', t, t);
    END LOOP;
END $$;


-- =============================================================================
-- SECTION 7. READ MODELS & CLOSE VIEWS
-- =============================================================================

-- Close Dashboard Summary View (Status of all subledgers per period)
CREATE OR REPLACE VIEW v_period_close_dashboard AS
SELECT cw.entity_id,
       p.period_name,
       cw.status AS workspace_status,
       count(sr.id) AS total_subledgers_tracked,
       count(sr.id) FILTER (WHERE sr.status = 'BALANCED') AS balanced_subledgers,
       count(sr.id) FILTER (WHERE abs(sr.variance) > 0.0001) AS variance_count,
       sum(abs(sr.variance)) AS total_absolute_variance
  FROM close_workspaces cw
  JOIN accounting_periods p ON p.id = cw.accounting_period_id
  LEFT JOIN subledger_reconciliations sr ON sr.workspace_id = cw.id
 GROUP BY cw.entity_id, p.period_name, cw.status;

-- AASB 15 Contract Asset & Liability Balance Report
CREATE OR REPLACE VIEW v_revenue_contract_position AS
SELECT rc.entity_id,
       rc.contract_number,
       cust.name AS customer_name,
       po.obligation_number,
       po.recognition_pattern,
       po.allocated_amount AS total_obligation_price,
       sum(COALESCE(rr.amount_recognised, 0)) AS revenue_recognised_to_date,
       po.allocated_amount - sum(COALESCE(rr.amount_recognised, 0)) AS remaining_unrecognised_liability
  FROM performance_obligations po
  JOIN revenue_contracts rc ON rc.id = po.contract_id
  JOIN parties cust         ON cust.id = rc.customer_party_id
  LEFT JOIN revenue_recognition_runs rr ON rr.obligation_id = po.id
 GROUP BY rc.entity_id, rc.contract_number, cust.name, po.obligation_number, po.recognition_pattern, po.allocated_amount;

-- ============================== END OF FILE ==================================

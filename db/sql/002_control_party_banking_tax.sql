-- =============================================================================
-- FILE:    002_control_party_banking_tax.sql
-- SYSTEM:  HRT Systems (Radical TG) - Database Design v2 Migration 002
-- PURPOSE: Expands the Accounting Kernel (001_tenant_schema_v2.sql) with:
--          1. Control Events Architecture (governance & non-posting event log)
--          2. Universal Multi-Role Party Model & Anti-Fraud Controls
--          3. Banking Subledger & Automated Statement Reconciliation Engine
--          4. Transaction Tax Subledger & AU/NZ Statutory BAS Engine
--          5. Open Items Fix for Credit Notes and Negative Balances
--
-- DESIGN RATIONALE:
--   * SDLC_22_Architectural_Rectification_and_Master_Schema_Roadmap.md
--   * Master Context Sections 71-78 (Party), 183-189 (Banking), 228-234 (Tax)
-- =============================================================================

-- =============================================================================
-- SECTION 1. CONTROL EVENTS ARCHITECTURE (GOVERNANCE LOG)
-- Events that govern operational truth, approvals, and workflows but do NOT
-- produce balanced financial journals (e.g. BankTransactionMatched,
-- AccountingPeriodClosed, EntityCertified, PurchaseOrderApproved, PartyApproved).
-- These remain 100% immutable and cryptographically hashed.
-- =============================================================================

CREATE TABLE control_events (
    id                    uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id             uuid         NOT NULL REFERENCES entities(id),
    event_type            varchar(100) NOT NULL CHECK (event_type ~ '^[A-Z][A-Za-z0-9]*$'),
    source_object_type    varchar(100) NOT NULL,
    source_object_id      uuid         NOT NULL,
    occurred_at           timestamptz  NOT NULL,
    recorded_at           timestamptz  NOT NULL DEFAULT now(),
    actor_id              uuid         REFERENCES users(id),
    correlation_id        uuid,
    idempotency_key       varchar(255) NOT NULL UNIQUE,
    payload               jsonb        NOT NULL,
    payload_sha256        bytea        NOT NULL,
    evidence_file_id      uuid         REFERENCES evidence_files(id),
    UNIQUE (id, entity_id)
);

CREATE FUNCTION trg_control_event_before_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
BEGIN
    NEW.recorded_at    := now();
    NEW.payload_sha256 := sha256(convert_to(NEW.payload::text, 'UTF8'));
    IF NEW.actor_id IS NULL THEN
        NEW.actor_id := hrt_current_actor();
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER t_control_events_before_insert
    BEFORE INSERT ON control_events
    FOR EACH ROW EXECUTE FUNCTION trg_control_event_before_insert();

CREATE TRIGGER t_control_events_immutable
    BEFORE UPDATE OR DELETE ON control_events
    FOR EACH ROW EXECUTE FUNCTION trg_reject_mutation();

CREATE TRIGGER t_control_events_no_truncate
    BEFORE TRUNCATE ON control_events
    FOR EACH STATEMENT EXECUTE FUNCTION trg_reject_mutation();

CREATE INDEX ix_control_events_lookup ON control_events (entity_id, event_type, occurred_at);
CREATE INDEX ix_control_events_source ON control_events (source_object_type, source_object_id);


-- =============================================================================
-- SECTION 2. UNIVERSAL MULTI-ROLE PARTY MODEL & ANTI-FRAUD CONTROLS
-- Replaces single-role party assumptions with a clean, extensible pattern:
--   parties -> party_roles -> party_profiles + party_bank_accounts
-- =============================================================================

-- A single party can hold multiple active roles simultaneously (e.g. Customer AND Supplier)
CREATE TABLE party_roles (
    id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    party_id    uuid         NOT NULL REFERENCES parties(id) ON DELETE RESTRICT,
    role_type   varchar(30)  NOT NULL
                CHECK (role_type IN ('CUSTOMER','SUPPLIER','EMPLOYEE','CONTRACTOR','INTERCOMPANY')),
    is_active   boolean      NOT NULL DEFAULT true,
    created_at  timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (party_id, role_type)
);

-- Role-specific commercial terms and accounting preferences
CREATE TABLE party_profiles (
    id                  uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    party_id            uuid         NOT NULL,
    role_type           varchar(30)  NOT NULL,
    payment_terms_days  integer      NOT NULL DEFAULT 30 CHECK (payment_terms_days >= 0),
    credit_limit        numeric(19,4),
    currency_code       char(3)      REFERENCES currencies(code),
    default_account_id  uuid         REFERENCES accounts(id),
    default_tax_code_id uuid         REFERENCES tax_codes(id),
    created_at          timestamptz  NOT NULL DEFAULT now(),
    updated_at          timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (party_id, role_type),
    FOREIGN KEY (party_id, role_type) REFERENCES party_roles (party_id, role_type) ON DELETE RESTRICT
);

-- Bank accounts belonging to a party (where AX sends supplier payments or refunds)
CREATE TABLE party_bank_accounts (
    id              uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    party_id        uuid         NOT NULL REFERENCES parties(id) ON DELETE RESTRICT,
    bank_name       varchar(100) NOT NULL,
    account_name    varchar(100) NOT NULL,
    routing_number  varchar(20)  NOT NULL, -- BSB for AU (e.g. '082-001'), Sort code for UK
    account_number  varchar(34)  NOT NULL, -- Bank account number or IBAN
    currency_code   char(3)      NOT NULL REFERENCES currencies(code),
    is_verified     boolean      NOT NULL DEFAULT false,
    is_primary      boolean      NOT NULL DEFAULT true,
    is_active       boolean      NOT NULL DEFAULT true,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now()
);

-- Master Context L75 & L172: Supplier bank account modification is the primary
-- vector for Business Email Compromise (BEC). Any change requires formal
-- verification and dual authorization before payment runs can release funds.
CREATE TABLE bank_account_change_requests (
    id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    party_id       uuid         NOT NULL REFERENCES parties(id),
    bank_account_id uuid        REFERENCES party_bank_accounts(id),
    action         varchar(20)  NOT NULL CHECK (action IN ('CREATE','UPDATE','DEACTIVATE')),
    status         varchar(20)  NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED')),
    requested_by   uuid         NOT NULL REFERENCES users(id),
    requested_at   timestamptz  NOT NULL DEFAULT now(),
    approved_by    uuid         REFERENCES users(id),
    approved_at    timestamptz,
    reason         varchar(500) NOT NULL,
    CHECK (status <> 'APPROVED' OR (approved_by IS NOT NULL AND approved_by <> requested_by))
);

-- Statutory tax registrations (ABN, NZBN, VAT Number) with effective dates
CREATE TABLE party_tax_registrations (
    id                  uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    party_id            uuid         NOT NULL REFERENCES parties(id) ON DELETE RESTRICT,
    tax_id_type         varchar(30)  NOT NULL, -- 'ABN', 'NZBN', 'EIN', 'VAT'
    registration_number varchar(50)  NOT NULL,
    country_code        char(2)      NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    is_gst_registered   boolean      NOT NULL DEFAULT true,
    valid_from          date         NOT NULL DEFAULT DATE '1900-01-01',
    valid_to            date,
    created_at          timestamptz  NOT NULL DEFAULT now(),
    CHECK (valid_to IS NULL OR valid_to >= valid_from),
    EXCLUDE USING gist (party_id WITH =, tax_id_type WITH =, daterange(valid_from, valid_to, '[]') WITH &&)
);


-- =============================================================================
-- SECTION 3. BANKING SUBLEDGER & RECONCILIATION ENGINE
-- Bridges bank feeds/statements to the GL Cash and Payment Clearing accounts.
-- =============================================================================

-- Internal bank accounts owned by the legal entity
CREATE TABLE bank_accounts (
    id                      uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id               uuid         NOT NULL REFERENCES entities(id),
    code                    varchar(30)  NOT NULL,
    name                    varchar(100) NOT NULL,
    bank_name               varchar(100) NOT NULL,
    bsb                     varchar(10),
    account_number          varchar(34)  NOT NULL,
    currency_code           char(3)      NOT NULL REFERENCES currencies(code),
    gl_account_id           uuid         NOT NULL REFERENCES accounts(id),          -- Cash at Bank
    gl_clearing_account_id  uuid         REFERENCES accounts(id),                   -- Payment Clearing Account
    is_active               boolean      NOT NULL DEFAULT true,
    created_at              timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (entity_id, code)
);

-- Bank statement headers (e.g. daily OFX/Open Banking feed batch or manual upload)
CREATE TABLE bank_statements (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    bank_account_id      uuid          NOT NULL REFERENCES bank_accounts(id),
    statement_identifier varchar(100)  NOT NULL, -- Feed batch ID or statement number
    opening_balance      numeric(19,4) NOT NULL,
    closing_balance      numeric(19,4) NOT NULL,
    start_date           date          NOT NULL,
    end_date             date          NOT NULL,
    status               varchar(20)   NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','RECONCILED')),
    created_at           timestamptz   NOT NULL DEFAULT now(),
    CHECK (end_date >= start_date),
    UNIQUE (bank_account_id, statement_identifier)
);

-- Immutable line-level feed transactions
CREATE TABLE bank_statement_lines (
    id                     uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    statement_id           uuid          NOT NULL REFERENCES bank_statements(id),
    line_number            integer       NOT NULL CHECK (line_number > 0),
    transaction_date       date          NOT NULL,
    value_date             date,
    amount                 numeric(19,4) NOT NULL CHECK (amount <> 0), -- + money in, - money out
    external_reference     varchar(255),                               -- bank fitid / transaction id
    counterparty_name      varchar(255),
    description            varchar(500)  NOT NULL,
    reconciliation_status  varchar(20)   NOT NULL DEFAULT 'UNRECONCILED'
                           CHECK (reconciliation_status IN ('UNRECONCILED','MATCHED','RECONCILED')),
    created_at             timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (statement_id, line_number)
);

-- Bank reconciliation session tracking
CREATE TABLE bank_reconciliation_sessions (
    id                       uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    bank_account_id          uuid          NOT NULL REFERENCES bank_accounts(id),
    accounting_period_id     uuid          NOT NULL REFERENCES accounting_periods(id),
    as_of_date               date          NOT NULL,
    statement_balance        numeric(19,4) NOT NULL,
    gl_balance               numeric(19,4) NOT NULL,
    unreconciled_difference  numeric(19,4) GENERATED ALWAYS AS (statement_balance - gl_balance) STORED,
    status                   varchar(20)   NOT NULL DEFAULT 'IN_PROGRESS'
                             CHECK (status IN ('IN_PROGRESS','COMPLETED','REVIEWED')),
    completed_at             timestamptz,
    completed_by             uuid          REFERENCES users(id),
    created_at               timestamptz   NOT NULL DEFAULT now()
);

-- Reusable matching engine records (1-to-1, 1-to-many, many-to-1, fees/adjustments)
CREATE TABLE bank_reconciliation_matches (
    id                        uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id                uuid          NOT NULL REFERENCES bank_reconciliation_sessions(id),
    statement_line_id         uuid          NOT NULL REFERENCES bank_statement_lines(id),
    matched_ledger_entry_id   uuid          REFERENCES ledger_entries(id),
    matched_allocation_id     uuid          REFERENCES open_item_allocations(id),
    matched_amount            numeric(19,4) NOT NULL CHECK (matched_amount <> 0),
    match_type                varchar(20)   NOT NULL
                              CHECK (match_type IN ('EXACT_1_TO_1','SPLIT_1_TO_MANY','RULE_AUTO','MANUAL')),
    created_at                timestamptz   NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 4. TAX SUBLEDGER & STATUTORY BAS ENGINE
-- Stores line-level taxable amounts and maps directly to statutory AU/NZ labels.
-- =============================================================================

CREATE TABLE tax_lines (
    id                          uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id                   uuid          NOT NULL REFERENCES entities(id),
    business_event_id           uuid          NOT NULL REFERENCES business_events(id),
    accounting_event_id         uuid          REFERENCES accounting_events(id),
    ledger_entry_id             uuid          REFERENCES ledger_entries(id),
    tax_code_id                 uuid          NOT NULL REFERENCES tax_codes(id),
    tax_date                    date          NOT NULL,
    taxable_amount              numeric(19,4) NOT NULL,
    tax_amount                  numeric(19,4) NOT NULL,
    recoverable_percentage      numeric(5,2)  NOT NULL DEFAULT 100.00
                                CHECK (recoverable_percentage BETWEEN 0 AND 100),
    recoverable_tax_amount      numeric(19,4) GENERATED ALWAYS AS
                                (round((tax_amount * recoverable_percentage / 100.0)::numeric, 4)) STORED,
    non_recoverable_tax_amount  numeric(19,4) GENERATED ALWAYS AS
                                (tax_amount - round((tax_amount * recoverable_percentage / 100.0)::numeric, 4)) STORED,
    bas_label                   varchar(10),  -- e.g. 'G1', 'G10', 'G11', '1A', '1B'
    created_at                  timestamptz   NOT NULL DEFAULT now()
);

-- Periodic Statutory Tax Filing (e.g. Quarterly Business Activity Statement - BAS)
CREATE TABLE tax_returns (
    id                               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id                        uuid          NOT NULL REFERENCES entities(id),
    jurisdiction                     varchar(10)   NOT NULL DEFAULT 'AU',
    tax_period_name                  varchar(50)   NOT NULL, -- e.g. '2026-Q1'
    from_date                        date          NOT NULL,
    to_date                          date          NOT NULL,
    status                           varchar(20)   NOT NULL DEFAULT 'DRAFT'
                                     CHECK (status IN ('DRAFT','LOCKED','FILED','PAID')),
    total_sales_g1                   numeric(19,4) NOT NULL DEFAULT 0,
    gst_on_sales_1a                  numeric(19,4) NOT NULL DEFAULT 0,
    gst_on_purchases_1b              numeric(19,4) NOT NULL DEFAULT 0,
    net_gst_payable_refundable       numeric(19,4) GENERATED ALWAYS AS
                                     (gst_on_sales_1a - gst_on_purchases_1b) STORED,
    payg_withholding_4               numeric(19,4) NOT NULL DEFAULT 0,
    payg_instalment_5a               numeric(19,4) NOT NULL DEFAULT 0,
    total_amount_payable_refundable  numeric(19,4) GENERATED ALWAYS AS
                                     ((gst_on_sales_1a - gst_on_purchases_1b) + payg_withholding_4 + payg_instalment_5a) STORED,
    filed_at                         timestamptz,
    filed_by                         uuid          REFERENCES users(id),
    lodgement_reference              varchar(100),
    created_at                       timestamptz   NOT NULL DEFAULT now(),
    CHECK (to_date >= from_date),
    UNIQUE (entity_id, jurisdiction, tax_period_name)
);


-- =============================================================================
-- SECTION 5. OPEN ITEMS RECTIFICATION FOR CREDIT NOTES & OVERPAYMENTS
-- Rectifies gap where original_amount was constrained > 0, which prevented
-- issuing Credit Notes or registering unapplied credit items.
-- =============================================================================

ALTER TABLE open_items DROP CONSTRAINT IF EXISTS open_items_original_amount_check;
ALTER TABLE open_items ADD CONSTRAINT open_items_original_amount_check CHECK (original_amount <> 0);

-- Update the allocation guard to cleanly support signed credit note allocations
CREATE OR REPLACE FUNCTION trg_allocation_before_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_original   numeric;
    v_allocated  numeric;
BEGIN
    SELECT original_amount INTO v_original FROM open_items WHERE id = NEW.open_item_id FOR UPDATE;
    SELECT COALESCE(sum(amount), 0) INTO v_allocated FROM open_item_allocations WHERE open_item_id = NEW.open_item_id;

    IF v_original > 0 THEN
        IF v_allocated + NEW.amount > v_original THEN
            RAISE EXCEPTION 'HRT-SUB-001: allocation of % exceeds outstanding balance % on debit open item %',
                NEW.amount, v_original - v_allocated, NEW.open_item_id;
        END IF;
        IF v_allocated + NEW.amount < 0 THEN
            RAISE EXCEPTION 'HRT-SUB-002: un-allocation of % would take open item % below zero allocated',
                NEW.amount, NEW.open_item_id;
        END IF;
    ELSE
        -- Credit note / negative open item allocation
        IF v_allocated + NEW.amount < v_original THEN
            RAISE EXCEPTION 'HRT-SUB-003: allocation of % exceeds available credit % on credit open item %',
                NEW.amount, abs(v_original - v_allocated), NEW.open_item_id;
        END IF;
        IF v_allocated + NEW.amount > 0 THEN
            RAISE EXCEPTION 'HRT-SUB-004: credit allocation exceeds zero boundary on credit open item %',
                NEW.open_item_id;
        END IF;
    END IF;

    RETURN NEW;
END $$;


-- =============================================================================
-- SECTION 6. TRIGGER WIRING & IMMUTABILITY ENFORCEMENT
-- =============================================================================

-- Immutability on financial lines & subledger matches
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'control_events', 'bank_statement_lines', 'bank_reconciliation_matches', 'tax_lines']
    LOOP
        EXECUTE format('CREATE TRIGGER t_%s_immutable BEFORE UPDATE OR DELETE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_reject_mutation()', t, t);
        EXECUTE format('CREATE TRIGGER t_%s_no_truncate BEFORE TRUNCATE ON %I
                        FOR EACH STATEMENT EXECUTE FUNCTION trg_reject_mutation()', t, t);
    END LOOP;
END $$;

-- Audit trail on master data & settings
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'party_roles', 'party_profiles', 'party_bank_accounts', 'party_tax_registrations',
        'bank_accounts', 'bank_statements', 'bank_reconciliation_sessions', 'tax_returns',
        'bank_account_change_requests']
    LOOP
        EXECUTE format('CREATE TRIGGER t_%s_audit AFTER INSERT OR UPDATE OR DELETE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_audit_row()', t, t);
    END LOOP;
END $$;


-- =============================================================================
-- SECTION 7. INDEXES & QUERY ACCELERATION
-- =============================================================================

CREATE INDEX ix_party_roles_party        ON party_roles (party_id);
CREATE INDEX ix_party_profiles_party     ON party_profiles (party_id, role_type);
CREATE INDEX ix_party_bank_accts_party   ON party_bank_accounts (party_id) WHERE is_active;
CREATE INDEX ix_bank_stmt_lines_unrec    ON bank_statement_lines (statement_id, reconciliation_status);
CREATE INDEX ix_tax_lines_tax_date       ON tax_lines (entity_id, tax_date);
CREATE INDEX ix_tax_lines_bas_label      ON tax_lines (entity_id, bas_label, tax_date);
CREATE INDEX ix_rec_matches_stmt_line    ON bank_reconciliation_matches (statement_line_id);


-- =============================================================================
-- SECTION 8. READ MODELS & SUMMARY VIEWS
-- =============================================================================

-- Unreconciled bank statement transactions for the Banking Workspace UI
CREATE OR REPLACE VIEW v_bank_statement_unreconciled AS
SELECT bsl.id AS statement_line_id,
       bs.bank_account_id,
       ba.code AS bank_account_code,
       ba.currency_code,
       bsl.transaction_date,
       bsl.amount,
       bsl.external_reference,
       bsl.counterparty_name,
       bsl.description
  FROM bank_statement_lines bsl
  JOIN bank_statements bs ON bs.id = bsl.statement_id
  JOIN bank_accounts ba   ON ba.id = bs.bank_account_id
 WHERE bsl.reconciliation_status = 'UNRECONCILED';

-- Quarterly / Monthly BAS summary aggregator for Australian tax compliance
CREATE OR REPLACE VIEW v_bas_summary AS
SELECT tl.entity_id,
       tl.bas_label,
       tc.code AS tax_code,
       date_trunc('quarter', tl.tax_date)::date AS quarter_start,
       sum(tl.taxable_amount)                   AS total_taxable_amount,
       sum(tl.tax_amount)                       AS total_tax_amount,
       sum(tl.recoverable_tax_amount)           AS total_recoverable_tax,
       sum(tl.non_recoverable_tax_amount)       AS total_non_recoverable_tax
  FROM tax_lines tl
  JOIN tax_codes tc ON tc.id = tl.tax_code_id
 WHERE tl.bas_label IS NOT NULL
 GROUP BY tl.entity_id, tl.bas_label, tc.code, date_trunc('quarter', tl.tax_date);

-- Multi-role party overview for the CRM / Master Data UI
CREATE OR REPLACE VIEW v_party_summary AS
SELECT p.id AS party_id,
       p.code,
       p.name,
       p.default_currency,
       p.is_active,
       string_agg(pr.role_type, ', ' ORDER BY pr.role_type) AS roles,
       bool_or(ptr.is_gst_registered)                       AS is_gst_registered,
       max(ptr.registration_number)                         AS abn_or_tax_id
  FROM parties p
  LEFT JOIN party_roles pr              ON pr.party_id = p.id AND pr.is_active
  LEFT JOIN party_tax_registrations ptr ON ptr.party_id = p.id
 GROUP BY p.id, p.code, p.name, p.default_currency, p.is_active;

-- ============================== END OF FILE ==================================

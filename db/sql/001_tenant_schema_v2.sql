-- =============================================================================
-- FILE:    001_tenant_schema_v2.sql
-- SYSTEM:  HRT Systems (Radical TG) - Accounting Kernel, Database Design v2
-- PURPOSE: Creates every table, constraint, trigger and view that ONE customer
--          (tenant) needs. The file is run once inside each tenant schema.
--
-- HOW THIS FILE FITS WITH THE REST OF THE SYSTEM
--   * Radical TG Control Plane (SDLC_19) creates one schema per customer,
--     e.g.  CREATE SCHEMA tenant_acme;  SET search_path = tenant_acme, public;
--     and then runs this file. Every tenant therefore has an identical
--     structure (zero version drift). Later changes ship as numbered
--     migration files (002_..., 003_...) which the Control Plane applies to
--     every tenant schema in the fleet.
--   * The FastAPI backend (SDLC_15) INSERTS business events, accounting events
--     and ledger lines. It can never UPDATE or DELETE posted financial rows:
--     the triggers in Section 6 make that physically impossible.
--   * Reporting and the HRT Assistant (SDLC_16 / SDLC_17) read from
--     period_balances and v_trial_balance instead of scanning ledger_entries.
--   * Design rationale: ERP_Architecture_Docs/SDLC_21_Database_Design_v2.md
--   * Proof that the rules work: sql/tests/verify_schema_v2.sql
--
-- CONVENTIONS
--   * DEBITS ARE POSITIVE, CREDITS ARE NEGATIVE (signed amounts).
--   * Money is NUMERIC(19,4). Exchange rates are NUMERIC(28,12).
--   * Primary keys are UUIDs. The application should generate UUIDv7
--     (time ordered = index friendly). gen_random_uuid() is only a fallback.
--   * The application runs  SET LOCAL hrt.actor_id = '<user uuid>'  at the
--     start of every transaction so the audit log records who did what.
--   * Error messages start with a code (e.g. HRT-BAL-002) so the API layer
--     can translate them into friendly UI messages.
--   * Every function is created with "SET search_path FROM CURRENT", which
--     pins it to THIS tenant schema. A trigger in tenant A can never read or
--     write tenant B's tables, even if a session's search_path is wrong.
-- =============================================================================


-- =============================================================================
-- SECTION 0. DATABASE-LEVEL EXTENSIONS
-- btree_gist lets an exclusion constraint combine "same entity" (=) with
-- "overlapping dates" (&&). It is installed once per database in "public".
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


-- =============================================================================
-- SECTION 1. REFERENCE DATA & TENANT SETTINGS
-- =============================================================================

-- ISO 4217 currencies. minor_units drives rounding tolerance (JPY = 0, AUD = 2).
CREATE TABLE currencies (
    code         char(3)      PRIMARY KEY CHECK (code ~ '^[A-Z]{3}$'),
    name         varchar(100) NOT NULL,
    minor_units  smallint     NOT NULL DEFAULT 2 CHECK (minor_units BETWEEN 0 AND 4),
    is_active    boolean      NOT NULL DEFAULT true
);

-- Exactly one row per tenant (enforced by the boolean primary key).
-- group_reporting_currency is the currency every ledger line is ALSO stored
-- in (Decision Q3), so consolidation never has to re-derive historical rates.
CREATE TABLE tenant_settings (
    singleton                 boolean     PRIMARY KEY DEFAULT true CHECK (singleton),
    tenant_code               varchar(50) NOT NULL,
    group_reporting_currency  char(3)     NOT NULL REFERENCES currencies(code),
    created_at                timestamptz NOT NULL DEFAULT now()
);

-- People who can act in this tenant. Roles/SoD live in the security module
-- (SDLC_13); this table exists here so every financial row can reference
-- a real user as its actor.
CREATE TABLE users (
    id            uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    email         varchar(320) NOT NULL,
    display_name  varchar(200) NOT NULL,
    is_active     boolean      NOT NULL DEFAULT true,
    created_at    timestamptz  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_users_email ON users (lower(email));


-- =============================================================================
-- SECTION 2. ORGANISATION: ENTITIES, PARALLEL LEDGERS, PERIODS, CLOSE GATES
-- =============================================================================

-- A legal entity (company) inside the tenant. Groups of entities are
-- consolidated through parent_entity_id.
CREATE TABLE entities (
    id                uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    code              varchar(30)  NOT NULL UNIQUE,
    legal_name        varchar(200) NOT NULL,
    base_currency     char(3)      NOT NULL REFERENCES currencies(code),
    country_code      char(2)      NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    parent_entity_id  uuid         REFERENCES entities(id),
    is_active         boolean      NOT NULL DEFAULT true,
    created_at        timestamptz  NOT NULL DEFAULT now(),
    CHECK (parent_entity_id IS NULL OR parent_entity_id <> id)
);

-- PARALLEL LEDGERS (Decision Q2). One business event produces one accounting
-- event PER LEDGER, e.g. an AASB book, an Australian tax book and a group
-- IFRS book, each interpreted by its own accounting rule version.
CREATE TABLE ledgers (
    id                    uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id             uuid         NOT NULL REFERENCES entities(id),
    code                  varchar(30)  NOT NULL,
    name                  varchar(200) NOT NULL,
    ledger_type           varchar(20)  NOT NULL
                          CHECK (ledger_type IN ('PRIMARY','TAX','GROUP','MANAGEMENT')),
    accounting_framework  varchar(30)  NOT NULL,          -- e.g. AASB, IFRS, TAX_AU
    ledger_currency       char(3)      NOT NULL REFERENCES currencies(code),
    is_active             boolean      NOT NULL DEFAULT true,
    created_at            timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (entity_id, code),
    UNIQUE (id, entity_id)       -- target for composite FKs (same-entity guarantee)
);
-- Each entity has exactly one PRIMARY (statutory) ledger.
CREATE UNIQUE INDEX ux_ledgers_one_primary ON ledgers (entity_id) WHERE ledger_type = 'PRIMARY';

-- Accounting periods per entity. REGULAR periods may never overlap;
-- ADJUSTMENT periods (e.g. "period 13" for audit adjustments) may.
CREATE TABLE accounting_periods (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id      uuid        NOT NULL REFERENCES entities(id),
    fiscal_year    integer     NOT NULL,
    period_number  smallint    NOT NULL CHECK (period_number BETWEEN 1 AND 16),
    period_name    varchar(50) NOT NULL,
    period_type    varchar(20) NOT NULL DEFAULT 'REGULAR'
                   CHECK (period_type IN ('REGULAR','ADJUSTMENT')),
    start_date     date        NOT NULL,
    end_date       date        NOT NULL,
    status         varchar(20) NOT NULL DEFAULT 'FUTURE'
                   CHECK (status IN ('FUTURE','OPEN','PENDING_CLOSE','CLOSED','REOPENED')),
    closed_at      timestamptz,
    closed_by      uuid        REFERENCES users(id),
    CHECK (end_date >= start_date),
    UNIQUE (entity_id, fiscal_year, period_number),
    UNIQUE (id, entity_id),
    EXCLUDE USING gist (entity_id WITH =, daterange(start_date, end_date, '[]') WITH &&)
        WHERE (period_type = 'REGULAR')
);

-- Append-only history of every period status change (who closed/reopened what).
CREATE TABLE period_status_history (
    id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    period_id    uuid        NOT NULL REFERENCES accounting_periods(id),
    from_status  varchar(20) NOT NULL,
    to_status    varchar(20) NOT NULL,
    changed_at   timestamptz NOT NULL DEFAULT now(),
    changed_by   uuid        REFERENCES users(id)
);

-- Catalogue of close gates. Replaces the hardcoded ap_ready_status /
-- ar_ready_status columns from SDLC_12 so new modules can add gates as data.
CREATE TABLE close_gate_definitions (
    gate_code     varchar(40)  PRIMARY KEY CHECK (gate_code ~ '^[A-Z][A-Z0-9_]*$'),
    description   varchar(200) NOT NULL,
    is_mandatory  boolean      NOT NULL DEFAULT false,
    is_active     boolean      NOT NULL DEFAULT true
);

-- Status of each gate for each period. A period can only be CLOSED once every
-- active mandatory gate is READY or WAIVED (enforced in Section 7).
CREATE TABLE period_close_gates (
    period_id   uuid        NOT NULL REFERENCES accounting_periods(id),
    gate_code   varchar(40) NOT NULL REFERENCES close_gate_definitions(gate_code),
    status      varchar(20) NOT NULL DEFAULT 'NOT_RUN'
                CHECK (status IN ('NOT_RUN','IN_PROGRESS','READY','WAIVED')),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid        REFERENCES users(id),
    PRIMARY KEY (period_id, gate_code)
);

-- Event 25 (AccountingPeriodReopened): a reopen needs a written reason and
-- approvals. consumed_at is stamped when the request is used to reopen.
CREATE TABLE period_reopen_requests (
    id            uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    period_id     uuid         NOT NULL REFERENCES accounting_periods(id),
    reason_code   varchar(50)  NOT NULL,
    reason_text   varchar(2000) NOT NULL,
    requested_by  uuid         NOT NULL REFERENCES users(id),
    requested_at  timestamptz  NOT NULL DEFAULT now(),
    consumed_at   timestamptz
);

CREATE TABLE period_reopen_approvals (
    request_id   uuid        NOT NULL REFERENCES period_reopen_requests(id),
    approver_id  uuid        NOT NULL REFERENCES users(id),
    approved_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (request_id, approver_id)
);


-- =============================================================================
-- SECTION 3. CHART OF ACCOUNTS & DYNAMIC DIMENSIONS
-- =============================================================================

-- "Thin" natural accounts. Analysis detail lives in dimensions, not in
-- thousands of account codes. normal_balance is derived, never typed in.
CREATE TABLE accounts (
    id                  uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    code                varchar(30)  NOT NULL UNIQUE,
    name                varchar(200) NOT NULL,
    account_type        varchar(20)  NOT NULL
                        CHECK (account_type IN ('ASSET','LIABILITY','EQUITY','REVENUE','EXPENSE')),
    normal_balance      char(2)      GENERATED ALWAYS AS
                        (CASE WHEN account_type IN ('ASSET','EXPENSE') THEN 'DR' ELSE 'CR' END) STORED,
    parent_account_id   uuid         REFERENCES accounts(id),
    is_postable         boolean      NOT NULL DEFAULT true,   -- false = heading/roll-up only
    is_control_account  boolean      NOT NULL DEFAULT false,  -- AR/AP: only subledgers post here
    is_active           boolean      NOT NULL DEFAULT true,
    created_at          timestamptz  NOT NULL DEFAULT now()
);

-- Tenant-defined dimensions (Department, Region, Project, Grant, Machine...).
CREATE TABLE dimensions (
    id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    code        varchar(30)  NOT NULL UNIQUE,
    name        varchar(100) NOT NULL,
    sort_order  smallint     NOT NULL DEFAULT 0,
    is_active   boolean      NOT NULL DEFAULT true
);

-- Allowed values per dimension, with hierarchy and effective dating.
CREATE TABLE dimension_values (
    id               uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    dimension_id     uuid         NOT NULL REFERENCES dimensions(id),
    code             varchar(50)  NOT NULL,
    name             varchar(200) NOT NULL,
    parent_value_id  uuid         REFERENCES dimension_values(id),
    valid_from       date         NOT NULL DEFAULT DATE '1900-01-01',
    valid_to         date,
    is_active        boolean      NOT NULL DEFAULT true,
    CHECK (valid_to IS NULL OR valid_to >= valid_from),
    UNIQUE (dimension_id, code),
    UNIQUE (id, dimension_id)    -- lets dimension_set_items prove value belongs to dimension
);

-- DIMENSION SETS: every unique combination of dimension values is stored ONCE.
-- Ledger lines carry a single dimension_set_id, which keeps strict FK
-- validation AND makes trial-balance indexes small and fast.
-- set_hash = sha256 of the sorted "dimension_id:value_id" pairs.
-- Always create sets through get_or_create_dimension_set() (Section 5).
CREATE TABLE dimension_sets (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    set_hash    bytea       NOT NULL UNIQUE,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE dimension_set_items (
    dimension_set_id    uuid NOT NULL REFERENCES dimension_sets(id),
    dimension_id        uuid NOT NULL REFERENCES dimensions(id),
    dimension_value_id  uuid NOT NULL,
    PRIMARY KEY (dimension_set_id, dimension_id),           -- max one value per dimension
    FOREIGN KEY (dimension_value_id, dimension_id)
        REFERENCES dimension_values (id, dimension_id)      -- value must belong to that dimension
);

-- "Account X requires dimension Y" (e.g. Travel Expense requires Department).
CREATE TABLE account_dimension_rules (
    account_id    uuid NOT NULL REFERENCES accounts(id),
    dimension_id  uuid NOT NULL REFERENCES dimensions(id),
    PRIMARY KEY (account_id, dimension_id)
);


-- =============================================================================
-- SECTION 4. FX, TAX, ACCOUNTING RULES, PARTIES, EVIDENCE
-- =============================================================================

-- Append-only rate table. A correction is a NEW row with revision + 1;
-- ledger lines keep pointing at the exact revision they used.
-- rate = units of to_currency per 1 unit of from_currency.
CREATE TABLE exchange_rates (
    id             uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
    from_currency  char(3)        NOT NULL REFERENCES currencies(code),
    to_currency    char(3)        NOT NULL REFERENCES currencies(code),
    rate_type      varchar(20)    NOT NULL
                   CHECK (rate_type IN ('SPOT','AVERAGE','CLOSING','HISTORICAL','CONTRACT')),
    rate_date      date           NOT NULL,
    rate           numeric(28,12) NOT NULL CHECK (rate > 0),
    revision       smallint       NOT NULL DEFAULT 1 CHECK (revision >= 1),
    source         varchar(100)   NOT NULL,
    created_at     timestamptz    NOT NULL DEFAULT now(),
    CHECK (from_currency <> to_currency),
    UNIQUE (from_currency, to_currency, rate_type, rate_date, revision)
);

CREATE TABLE tax_codes (
    id            uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    code          varchar(30)  NOT NULL UNIQUE,
    name          varchar(200) NOT NULL,
    jurisdiction  varchar(50)  NOT NULL,       -- e.g. AU, NZ, US-CA
    tax_type      varchar(20)  NOT NULL
                  CHECK (tax_type IN ('GST','VAT','SALES_TAX','WITHHOLDING','NONE')),
    is_active     boolean      NOT NULL DEFAULT true
);

-- Effective-dated tax rates; no two rates for one code may overlap in time.
CREATE TABLE tax_rates (
    id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    tax_code_id  uuid         NOT NULL REFERENCES tax_codes(id),
    rate         numeric(9,6) NOT NULL CHECK (rate >= 0),   -- 0.100000 = 10%
    valid_from   date         NOT NULL,
    valid_to     date,
    CHECK (valid_to IS NULL OR valid_to >= valid_from),
    EXCLUDE USING gist (tax_code_id WITH =, daterange(valid_from, valid_to, '[]') WITH &&)
);

-- Accounting rules and their immutable versions. Every accounting event
-- records the exact rule version that interpreted it (Phase 3B matrix).
CREATE TABLE accounting_rules (
    id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    code         varchar(100) NOT NULL UNIQUE,     -- e.g. AR_INVOICE, AASB16_LEASE
    description  varchar(500) NOT NULL,
    created_at   timestamptz  NOT NULL DEFAULT now()
);

CREATE TABLE accounting_rule_versions (
    rule_id         uuid        NOT NULL REFERENCES accounting_rules(id),
    version         integer     NOT NULL CHECK (version >= 1),
    status          varchar(20) NOT NULL DEFAULT 'DRAFT'
                    CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
    effective_from  date        NOT NULL,
    definition      jsonb       NOT NULL,          -- machine-readable posting template
    approved_by     uuid        REFERENCES users(id),
    approved_at     timestamptz,
    PRIMARY KEY (rule_id, version),
    CHECK (status = 'DRAFT' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);

-- Customers, suppliers, employees (expense claims) and intercompany partners.
CREATE TABLE parties (
    id                uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    party_type        varchar(20)  NOT NULL
                      CHECK (party_type IN ('CUSTOMER','SUPPLIER','EMPLOYEE','INTERCOMPANY')),
    code              varchar(50)  NOT NULL UNIQUE,
    name              varchar(200) NOT NULL,
    default_currency  char(3)      REFERENCES currencies(code),
    is_active         boolean      NOT NULL DEFAULT true,
    created_at        timestamptz  NOT NULL DEFAULT now()
);

-- Source documents (PDF bills, receipts). The SHA-256 hash proves the file
-- in storage has not been swapped after upload (SDLC_13 evidence hashing).
CREATE TABLE evidence_files (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    storage_uri  varchar(1000) NOT NULL,
    sha256_hex   char(64)      NOT NULL CHECK (sha256_hex ~ '^[0-9a-f]{64}$'),
    mime_type    varchar(100)  NOT NULL,
    size_bytes   bigint        NOT NULL CHECK (size_bytes >= 0),
    uploaded_by  uuid          REFERENCES users(id),
    uploaded_at  timestamptz   NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 5. THE LEDGER CHAIN
--   business_events  ->  accounting_events (one per ledger)  ->  ledger_entries
-- =============================================================================

-- WHAT HAPPENED. Immutable. Written by the API / Temporal integrations.
-- idempotency_key is unique per tenant (schema-per-tenant makes this safe),
-- so an integration retrying the same webhook can never double-post.
CREATE TABLE business_events (
    id                    uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id             uuid         NOT NULL REFERENCES entities(id),
    event_type            varchar(100) NOT NULL CHECK (event_type ~ '^[A-Z][A-Za-z0-9]*$'),
    event_schema_version  smallint     NOT NULL DEFAULT 1,
    source_object_type    varchar(100) NOT NULL,       -- e.g. CustomerInvoice
    source_object_id      uuid         NOT NULL,
    party_id              uuid         REFERENCES parties(id),
    occurred_at           timestamptz  NOT NULL,       -- when it happened in the real world
    recorded_at           timestamptz  NOT NULL DEFAULT now(),
    actor_id              uuid         REFERENCES users(id),
    correlation_id        uuid,                        -- traces an API/Temporal chain
    causation_event_id    uuid         REFERENCES business_events(id),
    idempotency_key       varchar(255) NOT NULL UNIQUE,
    payload               jsonb        NOT NULL,
    payload_sha256        bytea        NOT NULL,       -- set by trigger; tamper evidence
    evidence_file_id      uuid         REFERENCES evidence_files(id),
    UNIQUE (id, entity_id)
);

-- Processing state lives HERE (append-only), not as a mutable status column
-- on business_events. Current state = latest row (see v_business_event_status).
CREATE TABLE event_processing_log (
    id                 bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    business_event_id  uuid         NOT NULL REFERENCES business_events(id),
    ledger_id          uuid         REFERENCES ledgers(id),
    status             varchar(20)  NOT NULL
                       CHECK (status IN ('RECEIVED','ACCOUNTED','FAILED','SKIPPED')),
    message            varchar(2000),
    created_at         timestamptz  NOT NULL DEFAULT now()
);

-- HOW IT WAS INTERPRETED, PER LEDGER. Immutable header of a balanced posting.
-- Composite FKs guarantee the event, ledger and period all belong to the
-- same entity. A correction is a NEW event with reverses_accounting_event_id.
CREATE TABLE accounting_events (
    id                            uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    business_event_id             uuid         NOT NULL,
    entity_id                     uuid         NOT NULL,
    ledger_id                     uuid         NOT NULL,
    accounting_period_id          uuid         NOT NULL,
    economic_date                 date         NOT NULL,
    accounting_date               date         NOT NULL,
    tax_date                      date,
    rule_id                       uuid         NOT NULL,
    rule_version                  integer      NOT NULL,
    reverses_accounting_event_id  uuid         UNIQUE REFERENCES accounting_events(id),
    description                   varchar(500),
    posted_at                     timestamptz  NOT NULL DEFAULT now(),
    posted_by                     uuid         REFERENCES users(id),
    UNIQUE (business_event_id, ledger_id),     -- one interpretation per ledger
    FOREIGN KEY (business_event_id, entity_id)    REFERENCES business_events (id, entity_id),
    FOREIGN KEY (ledger_id, entity_id)            REFERENCES ledgers (id, entity_id),
    FOREIGN KEY (accounting_period_id, entity_id) REFERENCES accounting_periods (id, entity_id),
    FOREIGN KEY (rule_id, rule_version)           REFERENCES accounting_rule_versions (rule_id, version),
    CHECK (reverses_accounting_event_id IS NULL OR reverses_accounting_event_id <> id)
);

-- WHERE IT WAS POSTED. Immutable debit/credit lines with ROW-LEVEL currency.
--   transaction_*  : the document currency (e.g. USD 1,000)
--   base_amount    : the LEDGER currency (e.g. AUD 1,500)  <- must balance
--   reporting_*    : the GROUP currency at the transaction-date rate (Q3)
--                    <- must also balance (rounding goes to an explicit line)
-- ledger_id / accounting_period_id / accounting_date are copied from the
-- header by trigger (never trusted from the caller) for fast indexing.
CREATE TABLE ledger_entries (
    id                    uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
    accounting_event_id   uuid           NOT NULL REFERENCES accounting_events(id),
    line_number           smallint       NOT NULL CHECK (line_number > 0),
    ledger_id             uuid           NOT NULL REFERENCES ledgers(id),
    accounting_period_id  uuid           NOT NULL REFERENCES accounting_periods(id),
    accounting_date       date           NOT NULL,
    account_id            uuid           NOT NULL REFERENCES accounts(id),
    dimension_set_id      uuid           NOT NULL REFERENCES dimension_sets(id),
    party_id              uuid           REFERENCES parties(id),
    tax_code_id           uuid           REFERENCES tax_codes(id),
    description           varchar(500),
    transaction_currency  char(3)        NOT NULL REFERENCES currencies(code),
    transaction_amount    numeric(19,4)  NOT NULL,
    exchange_rate         numeric(28,12) NOT NULL CHECK (exchange_rate > 0),
    exchange_rate_id      uuid           REFERENCES exchange_rates(id),
    base_amount           numeric(19,4)  NOT NULL,
    reporting_currency    char(3)        NOT NULL REFERENCES currencies(code),
    reporting_rate        numeric(28,12) NOT NULL CHECK (reporting_rate > 0),
    reporting_rate_id     uuid           REFERENCES exchange_rates(id),
    reporting_amount      numeric(19,4)  NOT NULL,
    -- Derived from the sign, so DR/CR can never contradict the amount (gap G4).
    entry_side            char(2)        GENERATED ALWAYS AS (
                              CASE WHEN base_amount > 0 OR (base_amount = 0 AND reporting_amount > 0)
                                   THEN 'DR' ELSE 'CR' END) STORED,
    created_at            timestamptz    NOT NULL DEFAULT now(),
    UNIQUE (accounting_event_id, line_number),
    CHECK (base_amount <> 0 OR reporting_amount <> 0),
    CHECK (transaction_amount = 0 OR base_amount = 0 OR sign(transaction_amount) = sign(base_amount)),
    CHECK (reporting_amount = 0 OR base_amount = 0 OR sign(reporting_amount) = sign(base_amount))
);

-- Pre-aggregated balances maintained by trigger on every ledger insert.
-- Trial balances and the HRT Assistant read this, not ledger_entries.
CREATE TABLE period_balances (
    ledger_id             uuid          NOT NULL REFERENCES ledgers(id),
    accounting_period_id  uuid          NOT NULL REFERENCES accounting_periods(id),
    account_id            uuid          NOT NULL REFERENCES accounts(id),
    dimension_set_id      uuid          NOT NULL REFERENCES dimension_sets(id),
    debit_base            numeric(21,4) NOT NULL DEFAULT 0,
    credit_base           numeric(21,4) NOT NULL DEFAULT 0,   -- stored as a positive magnitude
    net_base              numeric(21,4) GENERATED ALWAYS AS (debit_base - credit_base) STORED,
    net_reporting         numeric(21,4) NOT NULL DEFAULT 0,
    line_count            bigint        NOT NULL DEFAULT 0,
    PRIMARY KEY (ledger_id, accounting_period_id, account_id, dimension_set_id)
);


-- =============================================================================
-- SECTION 5b. AR / AP SUBLEDGER (open items)
-- Other subledgers (bank, inventory, fixed assets, leases, manufacturing)
-- follow the same pattern in later migrations.
-- =============================================================================

-- One row per invoice/bill/credit. Immutable. Outstanding = original - allocations.
CREATE TABLE open_items (
    id                 uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id          uuid          NOT NULL REFERENCES entities(id),
    party_id           uuid          NOT NULL REFERENCES parties(id),
    item_type          char(2)       NOT NULL CHECK (item_type IN ('AR','AP')),
    business_event_id  uuid          NOT NULL REFERENCES business_events(id),
    document_number    varchar(100)  NOT NULL,
    currency_code      char(3)       NOT NULL REFERENCES currencies(code),
    original_amount    numeric(19,4) NOT NULL CHECK (original_amount > 0),
    document_date      date          NOT NULL,
    due_date           date          NOT NULL CHECK (due_date >= document_date),
    created_at         timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, item_type, document_number)
);

-- Payments/credits applied to an open item. Immutable; an un-allocation
-- (e.g. Event 24 PaymentBounced) is a NEGATIVE allocation row.
CREATE TABLE open_item_allocations (
    id                            uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    open_item_id                  uuid          NOT NULL REFERENCES open_items(id),
    allocation_business_event_id  uuid          NOT NULL REFERENCES business_events(id),
    amount                        numeric(19,4) NOT NULL CHECK (amount <> 0),
    allocated_on                  date          NOT NULL,
    created_at                    timestamptz   NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 5c. INTEGRATION OUTBOX & AUDIT LOG
-- =============================================================================

-- Transactional outbox (SDLC_15): written in the same transaction as the
-- posting, then published to webhooks by a Temporal worker.
CREATE TABLE outbox_events (
    id                 uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    business_event_id  uuid         REFERENCES business_events(id),
    topic              varchar(100) NOT NULL,
    payload            jsonb        NOT NULL,
    created_at         timestamptz  NOT NULL DEFAULT now(),
    published_at       timestamptz,
    attempts           integer      NOT NULL DEFAULT 0
);

-- Every insert/update/delete on master data and configuration. Immutable.
CREATE TABLE audit_log (
    id           bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at  timestamptz  NOT NULL DEFAULT now(),
    actor_id     uuid,
    action       varchar(10)  NOT NULL,
    object_type  varchar(100) NOT NULL,
    object_id    text,
    before_data  jsonb,
    after_data   jsonb
);


-- =============================================================================
-- SECTION 6. FUNCTIONS - GENERIC GUARDS
-- =============================================================================

-- Reads the acting user that FastAPI set with SET LOCAL hrt.actor_id.
CREATE FUNCTION hrt_current_actor() RETURNS uuid
LANGUAGE sql STABLE
SET search_path FROM CURRENT
AS $$ SELECT NULLIF(current_setting('hrt.actor_id', true), '')::uuid $$;

-- IMMUTABILITY GUARD (gap G2). Attached to every financial-history table.
-- Blocks UPDATE, DELETE and TRUNCATE. Corrections must be reversing entries.
CREATE FUNCTION trg_reject_mutation() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
BEGIN
    RAISE EXCEPTION 'HRT-IMMUTABLE: % on %.% is not allowed. Financial history can only be corrected with a reversing entry.',
        TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
        USING ERRCODE = 'restrict_violation';
END $$;

-- AUDIT TRAIL. Records before/after JSON for every change to master data.
CREATE FUNCTION trg_audit_row() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_before jsonb := CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END;
    v_after  jsonb := CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END;
BEGIN
    INSERT INTO audit_log (actor_id, action, object_type, object_id, before_data, after_data)
    VALUES (hrt_current_actor(), TG_OP, TG_TABLE_NAME,
            COALESCE(v_after ->> 'id', v_before ->> 'id'), v_before, v_after);
    RETURN NULL;
END $$;

-- Stamps business events with server time and a SHA-256 of the payload.
CREATE FUNCTION trg_business_event_before_insert() RETURNS trigger
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

-- The ONLY supported way to obtain a dimension_set_id.
-- Input: an array of dimension_value ids (any order). Output: the id of the
-- set holding exactly those values, created if it does not yet exist.
-- Two callers passing the same values in a different order get the same id.
CREATE FUNCTION get_or_create_dimension_set(p_value_ids uuid[]) RETURNS uuid
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_ids       uuid[] := ARRAY(SELECT DISTINCT unnest(COALESCE(p_value_ids, '{}'::uuid[])));
    v_found     integer;
    v_dims      integer;
    v_key       text;
    v_hash      bytea;
    v_id        uuid;
BEGIN
    SELECT count(*), count(DISTINCT dimension_id),
           string_agg(dimension_id::text || ':' || id::text, '|' ORDER BY dimension_id, id)
      INTO v_found, v_dims, v_key
      FROM dimension_values
     WHERE id = ANY (v_ids);

    IF v_found <> cardinality(v_ids) THEN
        RAISE EXCEPTION 'HRT-DIM-002: one or more dimension values do not exist: %', v_ids;
    END IF;
    IF v_dims <> v_found THEN
        RAISE EXCEPTION 'HRT-DIM-003: a dimension set may hold only one value per dimension';
    END IF;

    v_hash := sha256(convert_to(COALESCE(v_key, ''), 'UTF8'));

    SELECT id INTO v_id FROM dimension_sets WHERE set_hash = v_hash;
    IF FOUND THEN
        RETURN v_id;
    END IF;

    INSERT INTO dimension_sets (set_hash) VALUES (v_hash)
    ON CONFLICT (set_hash) DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN            -- another transaction created it first
        SELECT id INTO v_id FROM dimension_sets WHERE set_hash = v_hash;
        RETURN v_id;
    END IF;

    INSERT INTO dimension_set_items (dimension_set_id, dimension_id, dimension_value_id)
    SELECT v_id, dimension_id, id FROM dimension_values WHERE id = ANY (v_ids);

    RETURN v_id;
END $$;


-- =============================================================================
-- SECTION 7. FUNCTIONS - ACCOUNTING KERNEL GUARDS
-- =============================================================================

-- Runs BEFORE each accounting event is inserted.
--   * period must be OPEN/REOPENED and contain the accounting date (gap G3)
--   * rule version must be approved (not DRAFT) and already effective
--   * a reversal must target the same ledger and cannot reverse a reversal
-- The period row is locked FOR SHARE so a concurrent "close period" (which
-- needs an exclusive row lock) waits until in-flight postings commit.
CREATE FUNCTION trg_accounting_event_before_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_period  accounting_periods%ROWTYPE;
    v_rule    accounting_rule_versions%ROWTYPE;
    v_orig    accounting_events%ROWTYPE;
BEGIN
    NEW.posted_at := now();
    NEW.posted_by := COALESCE(NEW.posted_by, hrt_current_actor());

    SELECT * INTO v_period FROM accounting_periods WHERE id = NEW.accounting_period_id FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'HRT-PERIOD-000: accounting period % does not exist', NEW.accounting_period_id;
    END IF;
    IF v_period.status NOT IN ('OPEN','REOPENED') THEN
        RAISE EXCEPTION 'HRT-PERIOD-001: period % is % - postings are only allowed into OPEN or REOPENED periods',
            v_period.period_name, v_period.status;
    END IF;
    IF NEW.accounting_date NOT BETWEEN v_period.start_date AND v_period.end_date THEN
        RAISE EXCEPTION 'HRT-PERIOD-002: accounting date % is outside period % (% to %)',
            NEW.accounting_date, v_period.period_name, v_period.start_date, v_period.end_date;
    END IF;

    SELECT * INTO v_rule FROM accounting_rule_versions
     WHERE rule_id = NEW.rule_id AND version = NEW.rule_version;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'HRT-RULE-001: accounting rule version not found';
    END IF;
    IF v_rule.status = 'DRAFT' THEN
        RAISE EXCEPTION 'HRT-RULE-002: rule version % is still DRAFT and cannot post', NEW.rule_version;
    END IF;
    IF v_rule.effective_from > NEW.accounting_date THEN
        RAISE EXCEPTION 'HRT-RULE-003: rule version % is only effective from %', NEW.rule_version, v_rule.effective_from;
    END IF;

    IF NEW.reverses_accounting_event_id IS NOT NULL THEN
        SELECT * INTO v_orig FROM accounting_events WHERE id = NEW.reverses_accounting_event_id;
        IF v_orig.ledger_id <> NEW.ledger_id THEN
            RAISE EXCEPTION 'HRT-REV-001: a reversal must be posted to the same ledger as the original';
        END IF;
        IF v_orig.reverses_accounting_event_id IS NOT NULL THEN
            RAISE EXCEPTION 'HRT-REV-002: a reversal cannot itself be reversed - post a new event instead';
        END IF;
    END IF;

    RETURN NEW;
END $$;

-- Runs BEFORE each ledger line is inserted.
--   * copies ledger/period/date from the header (never trusted from caller)
--   * re-checks the period is still open
--   * enforces FX consistency: same-currency lines use rate 1; converted
--     amounts must equal amount x rate within one minor unit
--   * reporting currency must be the tenant's group currency
--   * account must be active and postable; control accounts (AR/AP) need a
--     party and cannot be hit by a manual journal
--   * required dimensions must be present; values must be active and valid on
--     the accounting date (skipped for reversals so old entries can be undone)
CREATE FUNCTION trg_ledger_entry_before_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_hdr           accounting_events%ROWTYPE;
    v_period_status varchar(20);
    v_ledger_ccy    char(3);
    v_ledger_minor  smallint;
    v_group_ccy     char(3);
    v_group_minor   smallint;
    v_acct          accounts%ROWTYPE;
    v_event_type    varchar(100);
    v_missing       text;
    v_invalid       text;
BEGIN
    SELECT * INTO v_hdr FROM accounting_events WHERE id = NEW.accounting_event_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'HRT-LINE-001: accounting event % does not exist', NEW.accounting_event_id;
    END IF;

    NEW.ledger_id            := v_hdr.ledger_id;
    NEW.accounting_period_id := v_hdr.accounting_period_id;
    NEW.accounting_date      := v_hdr.accounting_date;
    NEW.created_at           := now();

    SELECT status INTO v_period_status FROM accounting_periods
     WHERE id = v_hdr.accounting_period_id FOR SHARE;
    IF v_period_status NOT IN ('OPEN','REOPENED') THEN
        RAISE EXCEPTION 'HRT-PERIOD-001: period is % - postings are only allowed into OPEN or REOPENED periods', v_period_status;
    END IF;

    -- Currency checks -------------------------------------------------------
    SELECT l.ledger_currency, c.minor_units INTO v_ledger_ccy, v_ledger_minor
      FROM ledgers l JOIN currencies c ON c.code = l.ledger_currency
     WHERE l.id = v_hdr.ledger_id;
    SELECT s.group_reporting_currency, c.minor_units INTO v_group_ccy, v_group_minor
      FROM tenant_settings s JOIN currencies c ON c.code = s.group_reporting_currency;
    IF v_group_ccy IS NULL THEN
        RAISE EXCEPTION 'HRT-CONFIG-001: tenant_settings row is missing';
    END IF;

    IF NEW.transaction_currency = v_ledger_ccy
       AND (NEW.exchange_rate <> 1 OR NEW.transaction_amount <> NEW.base_amount) THEN
        RAISE EXCEPTION 'HRT-FX-001: line is in the ledger currency %, so exchange_rate must be 1 and transaction_amount must equal base_amount', v_ledger_ccy;
    END IF;
    IF NEW.reporting_currency <> v_group_ccy THEN
        RAISE EXCEPTION 'HRT-FX-002: reporting currency must be the group currency % (got %)', v_group_ccy, NEW.reporting_currency;
    END IF;
    IF v_ledger_ccy = v_group_ccy
       AND (NEW.reporting_rate <> 1 OR NEW.reporting_amount <> NEW.base_amount) THEN
        RAISE EXCEPTION 'HRT-FX-003: ledger and group currency are both %, so reporting_rate must be 1 and reporting_amount must equal base_amount', v_group_ccy;
    END IF;
    IF NEW.transaction_amount <> 0 AND NEW.base_amount <> 0
       AND abs(NEW.base_amount - NEW.transaction_amount * NEW.exchange_rate) > power(10::numeric, -v_ledger_minor) THEN
        RAISE EXCEPTION 'HRT-FX-004: base_amount % does not equal transaction_amount % x rate %',
            NEW.base_amount, NEW.transaction_amount, NEW.exchange_rate;
    END IF;
    IF NEW.base_amount <> 0 AND NEW.reporting_amount <> 0
       AND abs(NEW.reporting_amount - NEW.base_amount * NEW.reporting_rate) > power(10::numeric, -v_group_minor) THEN
        RAISE EXCEPTION 'HRT-FX-005: reporting_amount % does not equal base_amount % x reporting_rate %',
            NEW.reporting_amount, NEW.base_amount, NEW.reporting_rate;
    END IF;

    -- Account checks --------------------------------------------------------
    SELECT * INTO v_acct FROM accounts WHERE id = NEW.account_id;
    IF NOT v_acct.is_active OR NOT v_acct.is_postable THEN
        RAISE EXCEPTION 'HRT-ACCT-001: account % is inactive or not postable', v_acct.code;
    END IF;
    IF v_acct.is_control_account THEN
        SELECT event_type INTO v_event_type FROM business_events WHERE id = v_hdr.business_event_id;
        IF v_event_type = 'ManualJournalPosted' THEN
            RAISE EXCEPTION 'HRT-ACCT-002: account % is a control account; only its subledger may post to it (no manual journals)', v_acct.code;
        END IF;
        IF NEW.party_id IS NULL THEN
            RAISE EXCEPTION 'HRT-ACCT-003: control account % requires a party (customer/supplier) on the line', v_acct.code;
        END IF;
    END IF;

    -- Dimension checks ------------------------------------------------------
    SELECT string_agg(d.code, ', ' ORDER BY d.code) INTO v_missing
      FROM account_dimension_rules r
      JOIN dimensions d ON d.id = r.dimension_id
     WHERE r.account_id = NEW.account_id
       AND NOT EXISTS (SELECT 1 FROM dimension_set_items i
                        WHERE i.dimension_set_id = NEW.dimension_set_id
                          AND i.dimension_id = r.dimension_id);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'HRT-DIM-001: account % requires dimension(s): %', v_acct.code, v_missing;
    END IF;

    IF v_hdr.reverses_accounting_event_id IS NULL THEN
        SELECT string_agg(d.code || '=' || v.code, ', ') INTO v_invalid
          FROM dimension_set_items i
          JOIN dimension_values v ON v.id = i.dimension_value_id
          JOIN dimensions d       ON d.id = i.dimension_id
         WHERE i.dimension_set_id = NEW.dimension_set_id
           AND (NOT v.is_active OR NOT d.is_active
                OR v_hdr.accounting_date < v.valid_from
                OR (v.valid_to IS NOT NULL AND v_hdr.accounting_date > v.valid_to));
        IF v_invalid IS NOT NULL THEN
            RAISE EXCEPTION 'HRT-DIM-004: dimension value(s) % are inactive or not valid on %', v_invalid, v_hdr.accounting_date;
        END IF;
    END IF;

    RETURN NEW;
END $$;

-- Keeps period_balances in step with ledger_entries (same transaction, so a
-- rolled-back posting also rolls back its balance change).
CREATE FUNCTION trg_ledger_entry_after_insert_balance() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
BEGIN
    INSERT INTO period_balances AS pb
           (ledger_id, accounting_period_id, account_id, dimension_set_id,
            debit_base, credit_base, net_reporting, line_count)
    VALUES (NEW.ledger_id, NEW.accounting_period_id, NEW.account_id, NEW.dimension_set_id,
            GREATEST(NEW.base_amount, 0), GREATEST(-NEW.base_amount, 0), NEW.reporting_amount, 1)
    ON CONFLICT (ledger_id, accounting_period_id, account_id, dimension_set_id) DO UPDATE
       SET debit_base    = pb.debit_base    + EXCLUDED.debit_base,
           credit_base   = pb.credit_base   + EXCLUDED.credit_base,
           net_reporting = pb.net_reporting + EXCLUDED.net_reporting,
           line_count    = pb.line_count    + 1;
    RETURN NULL;
END $$;

-- DOUBLE-ENTRY GUARANTEE (gap G1). Deferred to COMMIT so all lines of an
-- event can be inserted first. Rejects the whole transaction unless:
--   * the event has at least two lines
--   * ledger-currency amounts sum to exactly zero
--   * group-currency amounts sum to exactly zero
--   * a reversal exactly mirrors the original (same accounts, dimensions,
--     parties and currencies with opposite amounts)
CREATE FUNCTION trg_check_event_balanced() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_count  integer;
    v_base   numeric;
    v_rep    numeric;
    v_rev_of uuid;
BEGIN
    SELECT count(*), COALESCE(sum(base_amount), 0), COALESCE(sum(reporting_amount), 0)
      INTO v_count, v_base, v_rep
      FROM ledger_entries WHERE accounting_event_id = NEW.accounting_event_id;

    IF v_count < 2 THEN
        RAISE EXCEPTION 'HRT-BAL-001: accounting event % has % line(s); at least 2 are required', NEW.accounting_event_id, v_count;
    END IF;
    IF v_base <> 0 THEN
        RAISE EXCEPTION 'HRT-BAL-002: accounting event % is not balanced in ledger currency (debits - credits = %)', NEW.accounting_event_id, v_base;
    END IF;
    IF v_rep <> 0 THEN
        RAISE EXCEPTION 'HRT-BAL-003: accounting event % is not balanced in group currency (difference %) - add an explicit rounding line', NEW.accounting_event_id, v_rep;
    END IF;

    SELECT reverses_accounting_event_id INTO v_rev_of FROM accounting_events WHERE id = NEW.accounting_event_id;
    IF v_rev_of IS NOT NULL AND EXISTS (
        (SELECT account_id, dimension_set_id, party_id, transaction_currency,
                sum(transaction_amount), sum(base_amount), sum(reporting_amount)
           FROM ledger_entries WHERE accounting_event_id = v_rev_of
          GROUP BY 1, 2, 3, 4
         EXCEPT
         SELECT account_id, dimension_set_id, party_id, transaction_currency,
                -sum(transaction_amount), -sum(base_amount), -sum(reporting_amount)
           FROM ledger_entries WHERE accounting_event_id = NEW.accounting_event_id
          GROUP BY 1, 2, 3, 4)
        UNION ALL
        (SELECT account_id, dimension_set_id, party_id, transaction_currency,
                -sum(transaction_amount), -sum(base_amount), -sum(reporting_amount)
           FROM ledger_entries WHERE accounting_event_id = NEW.accounting_event_id
          GROUP BY 1, 2, 3, 4
         EXCEPT
         SELECT account_id, dimension_set_id, party_id, transaction_currency,
                sum(transaction_amount), sum(base_amount), sum(reporting_amount)
           FROM ledger_entries WHERE accounting_event_id = v_rev_of
          GROUP BY 1, 2, 3, 4)
    ) THEN
        RAISE EXCEPTION 'HRT-REV-003: reversal event % does not exactly mirror the original event %', NEW.accounting_event_id, v_rev_of;
    END IF;

    RETURN NULL;
END $$;

-- An accounting event header with zero lines is also rejected at COMMIT.
CREATE FUNCTION trg_check_event_has_lines() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ledger_entries WHERE accounting_event_id = NEW.id) THEN
        RAISE EXCEPTION 'HRT-BAL-004: accounting event % has no ledger lines', NEW.id;
    END IF;
    RETURN NULL;
END $$;

-- PERIOD LIFECYCLE.
--   Allowed: FUTURE>OPEN, OPEN>PENDING_CLOSE, PENDING_CLOSE>OPEN,
--            PENDING_CLOSE>CLOSED, CLOSED>REOPENED, REOPENED>PENDING_CLOSE,
--            REOPENED>CLOSED
--   CLOSE   : every active mandatory gate must be READY or WAIVED.
--   REOPEN  : needs an unused reopen request plus approvals:
--             - normal tenants: 2 distinct approvers who are not the requester
--               (1 if the tenant only has 2 active users)
--             - SOLE OPERATOR EXCEPTION (SDLC_13): if the tenant has exactly
--               one active user, that user's own approval is enough.
--   Dates/entity are locked once the period has left FUTURE.
CREATE FUNCTION trg_period_before_update() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_missing       text;
    v_request_id    uuid;
    v_requester     uuid;
    v_active_users  integer;
    v_needed        integer;
    v_approvals     integer;
BEGIN
    IF (NEW.entity_id, NEW.fiscal_year, NEW.period_number, NEW.period_type, NEW.start_date, NEW.end_date)
       IS DISTINCT FROM
       (OLD.entity_id, OLD.fiscal_year, OLD.period_number, OLD.period_type, OLD.start_date, OLD.end_date)
       AND OLD.status <> 'FUTURE' THEN
        RAISE EXCEPTION 'HRT-PERIOD-003: period % has been opened; its dates and entity are locked', OLD.period_name;
    END IF;

    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    IF OLD.status || '>' || NEW.status NOT IN (
        'FUTURE>OPEN', 'OPEN>PENDING_CLOSE', 'PENDING_CLOSE>OPEN', 'PENDING_CLOSE>CLOSED',
        'CLOSED>REOPENED', 'REOPENED>PENDING_CLOSE', 'REOPENED>CLOSED') THEN
        RAISE EXCEPTION 'HRT-PERIOD-004: period status cannot move from % to %', OLD.status, NEW.status;
    END IF;

    IF NEW.status = 'CLOSED' THEN
        SELECT string_agg(g.gate_code, ', ' ORDER BY g.gate_code) INTO v_missing
          FROM close_gate_definitions g
         WHERE g.is_mandatory AND g.is_active
           AND NOT EXISTS (SELECT 1 FROM period_close_gates pg
                            WHERE pg.period_id = NEW.id
                              AND pg.gate_code = g.gate_code
                              AND pg.status IN ('READY','WAIVED'));
        IF v_missing IS NOT NULL THEN
            RAISE EXCEPTION 'HRT-CLOSE-001: period % cannot close; gates not ready: %', NEW.period_name, v_missing;
        END IF;
        NEW.closed_at := now();
        NEW.closed_by := COALESCE(hrt_current_actor(), NEW.closed_by);
    END IF;

    IF NEW.status = 'REOPENED' THEN
        SELECT id, requested_by INTO v_request_id, v_requester
          FROM period_reopen_requests
         WHERE period_id = NEW.id AND consumed_at IS NULL
         ORDER BY requested_at DESC
         LIMIT 1;
        IF v_request_id IS NULL THEN
            RAISE EXCEPTION 'HRT-REOPEN-001: period % has no open reopen request with a reason', NEW.period_name;
        END IF;

        SELECT count(*) INTO v_active_users FROM users WHERE is_active;
        IF v_active_users <= 1 THEN
            v_needed := 1;   -- Sole Operator Exception
            SELECT count(DISTINCT approver_id) INTO v_approvals
              FROM period_reopen_approvals WHERE request_id = v_request_id;
        ELSE
            v_needed := LEAST(2, v_active_users - 1);
            SELECT count(DISTINCT approver_id) INTO v_approvals
              FROM period_reopen_approvals
             WHERE request_id = v_request_id AND approver_id <> v_requester;
        END IF;

        IF v_approvals < v_needed THEN
            RAISE EXCEPTION 'HRT-REOPEN-002: reopening % needs % independent approval(s); found %', NEW.period_name, v_needed, v_approvals;
        END IF;

        UPDATE period_reopen_requests SET consumed_at = now() WHERE id = v_request_id;
        NEW.closed_at := NULL;
        NEW.closed_by := NULL;
    END IF;

    RETURN NEW;
END $$;

-- After a status change: write history; on reopen reset all gates so the
-- close checklist must be completed again.
CREATE FUNCTION trg_period_after_update() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO period_status_history (period_id, from_status, to_status, changed_by)
        VALUES (NEW.id, OLD.status, NEW.status, hrt_current_actor());

        IF NEW.status = 'REOPENED' THEN
            UPDATE period_close_gates
               SET status = 'NOT_RUN', updated_at = now(), updated_by = hrt_current_actor()
             WHERE period_id = NEW.id;
        END IF;
    END IF;
    RETURN NULL;
END $$;

-- Approved rule versions are frozen; only status can move ACTIVE > RETIRED.
CREATE FUNCTION trg_rule_version_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'HRT-RULE-004: rule version % is % and cannot be deleted', OLD.version, OLD.status;
        END IF;
        RETURN OLD;
    END IF;

    IF OLD.status <> 'DRAFT' AND (
           NEW.definition     IS DISTINCT FROM OLD.definition
        OR NEW.effective_from IS DISTINCT FROM OLD.effective_from
        OR NEW.rule_id        IS DISTINCT FROM OLD.rule_id
        OR NEW.version        IS DISTINCT FROM OLD.version) THEN
        RAISE EXCEPTION 'HRT-RULE-004: rule version % is % and is frozen; create a new version instead', OLD.version, OLD.status;
    END IF;
    IF OLD.status || '>' || NEW.status NOT IN ('DRAFT>DRAFT','DRAFT>ACTIVE','ACTIVE>ACTIVE','ACTIVE>RETIRED','RETIRED>RETIRED') THEN
        RAISE EXCEPTION 'HRT-RULE-005: rule version status cannot move from % to %', OLD.status, NEW.status;
    END IF;
    RETURN NEW;
END $$;

-- Prevents allocating more than an open item's value (or going below zero).
CREATE FUNCTION trg_allocation_before_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_original   numeric;
    v_allocated  numeric;
BEGIN
    SELECT original_amount INTO v_original FROM open_items WHERE id = NEW.open_item_id FOR UPDATE;
    SELECT COALESCE(sum(amount), 0) INTO v_allocated FROM open_item_allocations WHERE open_item_id = NEW.open_item_id;
    IF v_allocated + NEW.amount > v_original THEN
        RAISE EXCEPTION 'HRT-SUB-001: allocation of % exceeds outstanding balance % on open item %',
            NEW.amount, v_original - v_allocated, NEW.open_item_id;
    END IF;
    IF v_allocated + NEW.amount < 0 THEN
        RAISE EXCEPTION 'HRT-SUB-002: un-allocation of % would take open item % below zero allocated', NEW.amount, NEW.open_item_id;
    END IF;
    RETURN NEW;
END $$;

-- Group currency and ledger currency cannot change once anything is posted.
CREATE FUNCTION trg_tenant_settings_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'HRT-CONFIG-003: tenant_settings cannot be deleted';
    END IF;
    IF NEW.group_reporting_currency <> OLD.group_reporting_currency
       AND EXISTS (SELECT 1 FROM ledger_entries) THEN
        RAISE EXCEPTION 'HRT-CONFIG-002: group reporting currency cannot change after postings exist; this requires a formal restatement event';
    END IF;
    RETURN NEW;
END $$;

CREATE FUNCTION trg_ledger_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
DECLARE
    v_entity_ccy char(3);
BEGIN
    SELECT base_currency INTO v_entity_ccy FROM entities WHERE id = NEW.entity_id;
    IF NEW.ledger_type = 'PRIMARY' AND NEW.ledger_currency <> v_entity_ccy THEN
        RAISE EXCEPTION 'HRT-LEDGER-001: the PRIMARY ledger must use the entity base currency %', v_entity_ccy;
    END IF;
    IF TG_OP = 'UPDATE'
       AND (NEW.ledger_currency <> OLD.ledger_currency OR NEW.entity_id <> OLD.entity_id)
       AND EXISTS (SELECT 1 FROM ledger_entries WHERE ledger_id = OLD.id) THEN
        RAISE EXCEPTION 'HRT-LEDGER-002: ledger % has postings; its currency and entity are locked', OLD.code;
    END IF;
    RETURN NEW;
END $$;


-- =============================================================================
-- SECTION 8. TRIGGER WIRING
-- =============================================================================

-- 8.1 Immutability: financial history and evidence can never change.
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'business_events', 'event_processing_log', 'accounting_events', 'ledger_entries',
        'dimension_sets', 'dimension_set_items', 'exchange_rates', 'evidence_files',
        'open_items', 'open_item_allocations', 'audit_log', 'period_status_history',
        'period_reopen_approvals']
    LOOP
        EXECUTE format('CREATE TRIGGER t_%s_immutable BEFORE UPDATE OR DELETE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_reject_mutation()', t, t);
        EXECUTE format('CREATE TRIGGER t_%s_no_truncate BEFORE TRUNCATE ON %I
                        FOR EACH STATEMENT EXECUTE FUNCTION trg_reject_mutation()', t, t);
    END LOOP;
END $$;

-- 8.2 Audit trail on master data and configuration.
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'tenant_settings', 'users', 'entities', 'ledgers', 'accounting_periods',
        'close_gate_definitions', 'period_close_gates', 'period_reopen_requests',
        'period_reopen_approvals', 'accounts', 'dimensions', 'dimension_values',
        'account_dimension_rules', 'exchange_rates', 'tax_codes', 'tax_rates',
        'accounting_rules', 'accounting_rule_versions', 'parties']
    LOOP
        EXECUTE format('CREATE TRIGGER t_%s_audit AFTER INSERT OR UPDATE OR DELETE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_audit_row()', t, t);
    END LOOP;
END $$;

-- 8.3 Ledger chain.
CREATE TRIGGER t_business_events_before_insert
    BEFORE INSERT ON business_events
    FOR EACH ROW EXECUTE FUNCTION trg_business_event_before_insert();

CREATE TRIGGER t_accounting_events_before_insert
    BEFORE INSERT ON accounting_events
    FOR EACH ROW EXECUTE FUNCTION trg_accounting_event_before_insert();

CREATE CONSTRAINT TRIGGER ct_accounting_events_has_lines
    AFTER INSERT ON accounting_events
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_check_event_has_lines();

CREATE TRIGGER t_ledger_entries_before_insert
    BEFORE INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION trg_ledger_entry_before_insert();

CREATE TRIGGER t_ledger_entries_after_insert_balance
    AFTER INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION trg_ledger_entry_after_insert_balance();

CREATE CONSTRAINT TRIGGER ct_ledger_entries_balanced
    AFTER INSERT ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_check_event_balanced();

-- 8.4 Periods, rules, subledger, configuration.
CREATE TRIGGER t_accounting_periods_before_update
    BEFORE UPDATE ON accounting_periods
    FOR EACH ROW EXECUTE FUNCTION trg_period_before_update();

CREATE TRIGGER t_accounting_periods_after_update
    AFTER UPDATE ON accounting_periods
    FOR EACH ROW EXECUTE FUNCTION trg_period_after_update();

CREATE TRIGGER t_accounting_periods_no_delete
    BEFORE DELETE ON accounting_periods
    FOR EACH ROW EXECUTE FUNCTION trg_reject_mutation();

CREATE TRIGGER t_rule_versions_guard
    BEFORE UPDATE OR DELETE ON accounting_rule_versions
    FOR EACH ROW EXECUTE FUNCTION trg_rule_version_guard();

CREATE TRIGGER t_open_item_allocations_before_insert
    BEFORE INSERT ON open_item_allocations
    FOR EACH ROW EXECUTE FUNCTION trg_allocation_before_insert();

CREATE TRIGGER t_tenant_settings_guard
    BEFORE UPDATE OR DELETE ON tenant_settings
    FOR EACH ROW EXECUTE FUNCTION trg_tenant_settings_guard();

CREATE TRIGGER t_ledgers_guard
    BEFORE INSERT OR UPDATE ON ledgers
    FOR EACH ROW EXECUTE FUNCTION trg_ledger_guard();


-- =============================================================================
-- SECTION 9. INDEXES
-- =============================================================================
CREATE INDEX ix_ledger_entries_tb       ON ledger_entries (ledger_id, accounting_period_id, account_id, dimension_set_id);
CREATE INDEX ix_ledger_entries_account  ON ledger_entries (account_id, accounting_date);
CREATE INDEX ix_ledger_entries_party    ON ledger_entries (party_id) WHERE party_id IS NOT NULL;
CREATE INDEX ix_accounting_events_date  ON accounting_events (ledger_id, accounting_date);
CREATE INDEX ix_business_events_type    ON business_events (entity_id, event_type, occurred_at);
CREATE INDEX ix_business_events_source  ON business_events (source_object_type, source_object_id);
CREATE INDEX ix_business_events_corr    ON business_events (correlation_id) WHERE correlation_id IS NOT NULL;
CREATE INDEX ix_processing_log_event    ON event_processing_log (business_event_id, created_at);
CREATE INDEX ix_open_items_party        ON open_items (party_id);
CREATE INDEX ix_allocations_item        ON open_item_allocations (open_item_id);
CREATE INDEX ix_outbox_unpublished      ON outbox_events (created_at) WHERE published_at IS NULL;
CREATE INDEX ix_audit_object            ON audit_log (object_type, object_id);
CREATE INDEX ix_dimension_set_items_val ON dimension_set_items (dimension_value_id);


-- =============================================================================
-- SECTION 10. READ MODELS (views used by reporting and the HRT Assistant)
-- =============================================================================

-- Trial balance by ledger, period and account (all dimension sets summed).
CREATE VIEW v_trial_balance AS
SELECT l.code            AS ledger_code,
       p.period_name,
       a.code            AS account_code,
       a.name            AS account_name,
       a.account_type,
       sum(pb.debit_base)    AS debit,
       sum(pb.credit_base)   AS credit,
       sum(pb.net_base)      AS net_base,
       sum(pb.net_reporting) AS net_reporting,
       pb.ledger_id,
       pb.accounting_period_id,
       pb.account_id
  FROM period_balances pb
  JOIN ledgers l            ON l.id = pb.ledger_id
  JOIN accounting_periods p ON p.id = pb.accounting_period_id
  JOIN accounts a           ON a.id = pb.account_id
 GROUP BY l.code, p.period_name, a.code, a.name, a.account_type,
          pb.ledger_id, pb.accounting_period_id, pb.account_id;

-- Latest processing status of each business event per ledger.
CREATE VIEW v_business_event_status AS
SELECT DISTINCT ON (business_event_id, ledger_id)
       business_event_id, ledger_id, status, message, created_at
  FROM event_processing_log
 ORDER BY business_event_id, ledger_id, created_at DESC, id DESC;

-- Outstanding balance of every AR/AP open item.
CREATE VIEW v_open_item_balances AS
SELECT oi.id, oi.item_type, oi.party_id, oi.document_number, oi.currency_code,
       oi.original_amount,
       COALESCE(sum(a.amount), 0)                      AS allocated_amount,
       oi.original_amount - COALESCE(sum(a.amount), 0) AS outstanding_amount,
       oi.due_date
  FROM open_items oi
  LEFT JOIN open_item_allocations a ON a.open_item_id = oi.id
 GROUP BY oi.id;


-- =============================================================================
-- SECTION 11. SEED REFERENCE DATA (identical for every tenant)
-- =============================================================================
INSERT INTO currencies (code, name, minor_units) VALUES
    ('AUD', 'Australian Dollar', 2), ('NZD', 'New Zealand Dollar', 2),
    ('USD', 'US Dollar', 2),         ('EUR', 'Euro', 2),
    ('GBP', 'Pound Sterling', 2),    ('SGD', 'Singapore Dollar', 2),
    ('CNY', 'Chinese Yuan', 2),      ('JPY', 'Japanese Yen', 0),
    ('IDR', 'Indonesian Rupiah', 2);

INSERT INTO close_gate_definitions (gate_code, description, is_mandatory) VALUES
    ('AP_READY',            'Accounts payable reconciled to control account', true),
    ('AR_READY',            'Accounts receivable reconciled to control account', true),
    ('BANK_READY',          'All bank accounts reconciled', true),
    ('TAX_READY',           'GST/VAT/sales tax reconciled', true),
    ('INVENTORY_READY',     'Inventory subledger reconciled', false),
    ('FA_READY',            'Fixed asset register reconciled, depreciation run', false),
    ('PROJECTS_READY',      'Project WIP reviewed', false),
    ('PREPAYMENTS_READY',   'Prepayment amortisation run', false),
    ('PAYROLL_READY',       'Payroll journals posted and reconciled', false),
    ('FX_REVALUATION_DONE', 'Month-end unrealised FX revaluation posted', false);


-- =============================================================================
-- SECTION 12. PRIVILEGES (applied only if the application role exists)
-- The API role may read everything, INSERT financial history, and UPDATE only
-- master data. It has no UPDATE/DELETE on ledger tables at all - a second
-- lock on top of the immutability triggers.
-- =============================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hrt_app') THEN
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO hrt_app', current_schema());
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO hrt_app', current_schema());
        GRANT INSERT ON business_events, event_processing_log, accounting_events, ledger_entries,
                        open_items, open_item_allocations, evidence_files, exchange_rates,
                        dimension_sets, dimension_set_items, outbox_events,
                        period_reopen_requests, period_reopen_approvals TO hrt_app;
        GRANT INSERT, UPDATE ON users, entities, ledgers, accounting_periods, period_close_gates,
                        accounts, dimensions, dimension_values, account_dimension_rules,
                        tax_codes, tax_rates, accounting_rules, accounting_rule_versions,
                        parties, tenant_settings TO hrt_app;
        GRANT UPDATE (published_at, attempts) ON outbox_events TO hrt_app;
        EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO hrt_app', current_schema());
    END IF;
END $$;

-- ============================== END OF FILE ==================================

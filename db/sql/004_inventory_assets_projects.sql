-- =============================================================================
-- FILE:    004_inventory_assets_projects.sql
-- SYSTEM:  HRT Systems (Radical TG) - Database Design v2 Migration 004
-- PURPOSE: Implements operational subledgers for:
--          1. Perpetual Inventory & Valuation Layers - AASB 102 (Domain 10)
--          2. Fixed Assets & Dual-Book Depreciation - AASB 116 (Domain 11)
--          3. Lease Accounting & ROU Amortisation - AASB 16 (Domain 11)
--          4. Projects, Timesheets & Contract WIP - AASB 15 (Domain 12)
--          5. External Payroll Ingestion & Clearing (Domain 14)
--
-- DESIGN RATIONALE:
--   * Master Context Sections 190-193 (Inventory), 194-199 (Assets/Leases),
--     203-212 (Payroll), 213-220 (Projects)
--   * SDLC_22 Architectural Rectification & SDLC_23 Complete Data Architecture
--   * Strict Separation: AASB 116 Capital WIP (Account 1500) vs AASB 15 Contract WIP (Account 1400)
--   * Strict Valuation: AASB 102 FIFO/Avg Cost Layers with permanent quantity audit
-- =============================================================================


-- =============================================================================
-- SECTION 1. INVENTORY SUBLEDGER & COST LAYERS (DOMAIN 10 - AASB 102)
-- Perpetual inventory with quantity movements and independent cost layers.
-- =============================================================================

-- Warehouses, storage locations, service vehicles, and virtual in-transit hubs
CREATE TABLE inventory_locations (
    id            uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id     uuid         NOT NULL REFERENCES entities(id),
    code          varchar(30)  NOT NULL,
    name          varchar(100) NOT NULL,
    location_type varchar(20)  NOT NULL DEFAULT 'WAREHOUSE'
                  CHECK (location_type IN ('WAREHOUSE','RETAIL','VEHICLE','IN_TRANSIT','CONSIGNMENT')),
    address_id    uuid,
    is_active     boolean      NOT NULL DEFAULT true,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (entity_id, code)
);

-- Costing pools determining the valuation method per entity/item group
CREATE TABLE inventory_cost_pools (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id      uuid        NOT NULL REFERENCES entities(id),
    code           varchar(30) NOT NULL,
    costing_method varchar(20) NOT NULL
                   CHECK (costing_method IN ('FIFO','WEIGHTED_AVERAGE','SPECIFIC_ID')),
    description    varchar(200) NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (entity_id, code)
);

-- Stock on Hand (SOH) balance cache per item and location
CREATE TABLE inventory_items (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    item_id              uuid          NOT NULL REFERENCES items(id),
    location_id          uuid          NOT NULL REFERENCES inventory_locations(id),
    quantity_on_hand     numeric(19,4) NOT NULL DEFAULT 0,
    quantity_reserved    numeric(19,4) NOT NULL DEFAULT 0 CHECK (quantity_reserved >= 0),
    quantity_available   numeric(19,4) GENERATED ALWAYS AS (quantity_on_hand - quantity_reserved) STORED,
    last_counted_at      timestamptz,
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, item_id, location_id)
);

-- Immutable audit log of every physical movement
CREATE TABLE inventory_movements (
    id                 uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id          uuid          NOT NULL REFERENCES entities(id),
    business_event_id  uuid          NOT NULL REFERENCES business_events(id),
    item_id            uuid          NOT NULL REFERENCES items(id),
    location_id        uuid          NOT NULL REFERENCES inventory_locations(id),
    movement_type      varchar(20)   NOT NULL
                       CHECK (movement_type IN ('RECEIPT','ISSUE','TRANSFER_OUT','TRANSFER_IN','COUNT_ADJUST','SCRAP')),
    quantity           numeric(19,4) NOT NULL CHECK (quantity <> 0),
    uom_id             uuid          NOT NULL REFERENCES units_of_measure(id),
    unit_cost          numeric(19,4) NOT NULL CHECK (unit_cost >= 0),
    total_cost         numeric(19,4) NOT NULL,
    reference_document varchar(100), -- GRN number, Picking Slip ID
    occurred_at        timestamptz   NOT NULL,
    created_at         timestamptz   NOT NULL DEFAULT now()
);

-- Valuation Layers (FIFO / Specific Identification)
CREATE TABLE inventory_cost_layers (
    id                 uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id          uuid          NOT NULL REFERENCES entities(id),
    item_id            uuid          NOT NULL REFERENCES items(id),
    location_id        uuid          NOT NULL REFERENCES inventory_locations(id),
    layer_date         date          NOT NULL,
    original_quantity  numeric(19,4) NOT NULL CHECK (original_quantity > 0),
    remaining_quantity numeric(19,4) NOT NULL CHECK (remaining_quantity >= 0),
    unit_cost          numeric(19,4) NOT NULL CHECK (unit_cost >= 0),
    is_depleted        boolean       GENERATED ALWAYS AS (remaining_quantity = 0) STORED,
    created_at         timestamptz   NOT NULL DEFAULT now()
);

-- Stocktake Sessions & Counting Sheets
CREATE TABLE inventory_counts (
    id                   uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid         NOT NULL REFERENCES entities(id),
    location_id          uuid         NOT NULL REFERENCES inventory_locations(id),
    count_number         varchar(50)  NOT NULL,
    count_date           date         NOT NULL,
    status               varchar(20)  NOT NULL DEFAULT 'IN_PROGRESS'
                         CHECK (status IN ('IN_PROGRESS','REVIEWED','POSTED')),
    posted_by            uuid         REFERENCES users(id),
    posted_at            timestamptz,
    created_at           timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (entity_id, count_number)
);

CREATE TABLE inventory_count_lines (
    id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    count_id          uuid          NOT NULL REFERENCES inventory_counts(id) ON DELETE CASCADE,
    item_id           uuid          NOT NULL REFERENCES items(id),
    system_quantity   numeric(19,4) NOT NULL,
    counted_quantity  numeric(19,4) NOT NULL CHECK (counted_quantity >= 0),
    variance_quantity numeric(19,4) GENERATED ALWAYS AS (counted_quantity - system_quantity) STORED,
    unit_cost         numeric(19,4) NOT NULL,
    variance_cost     numeric(19,4) GENERATED ALWAYS AS ((counted_quantity - system_quantity) * unit_cost) STORED,
    notes             varchar(500),
    PRIMARY KEY (count_id, item_id)
);

-- Net Realisable Value (NRV) write-down allowances under AASB 102.34
CREATE TABLE inventory_nrv_allowances (
    id                 uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id          uuid          NOT NULL REFERENCES entities(id),
    item_id            uuid          NOT NULL REFERENCES items(id),
    accounting_period_id uuid        NOT NULL REFERENCES accounting_periods(id),
    cost_basis         numeric(19,4) NOT NULL CHECK (cost_basis >= 0),
    net_realisable_val numeric(19,4) NOT NULL CHECK (net_realisable_val >= 0),
    allowance_amount   numeric(19,4) GENERATED ALWAYS AS (GREATEST(0, cost_basis - net_realisable_val)) STORED,
    created_at         timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, item_id, accounting_period_id)
);


-- =============================================================================
-- SECTION 2. FIXED ASSETS & LEASES (DOMAIN 11 - AASB 116 & AASB 16)
-- Dual-book asset registers (AASB Book vs Tax Book) and Lease Liability Engine.
-- =============================================================================

-- Fixed Asset Master Registry
CREATE TABLE fixed_assets (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    asset_number         varchar(50)   NOT NULL,
    name                 varchar(200)  NOT NULL,
    serial_number        varchar(100),
    location_id          uuid          REFERENCES inventory_locations(id),
    custodian_user_id    uuid          REFERENCES users(id),
    acquisition_date     date          NOT NULL,
    in_service_date      date,
    original_cost        numeric(19,4) NOT NULL CHECK (original_cost >= 0),
    currency_code        char(3)       NOT NULL REFERENCES currencies(code),
    status               varchar(20)   NOT NULL DEFAULT 'DRAFT'
                         CHECK (status IN ('DRAFT','IN_SERVICE','FULLY_DEPRECIATED','DISPOSED')),
    created_at           timestamptz   NOT NULL DEFAULT now(),
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, asset_number)
);

-- Parallel Asset Books (Accounting Book vs Tax Book)
CREATE TABLE asset_books (
    id                       uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id                 uuid          NOT NULL REFERENCES fixed_assets(id) ON DELETE CASCADE,
    book_type                varchar(20)   NOT NULL CHECK (book_type IN ('AASB_BOOK','TAX_BOOK')),
    ledger_id                uuid          NOT NULL REFERENCES ledgers(id),
    asset_account_id         uuid          NOT NULL REFERENCES accounts(id), -- Asset (PPE)
    accum_deprec_account_id  uuid          NOT NULL REFERENCES accounts(id), -- Contra-Asset
    deprec_expense_account_id uuid         NOT NULL REFERENCES accounts(id), -- Expense
    depreciation_method      varchar(30)   NOT NULL
                             CHECK (depreciation_method IN ('STRAIGHT_LINE','DIMINISHING_VALUE','UNITS_OF_PRODUCTION')),
    useful_life_months       integer       NOT NULL CHECK (useful_life_months > 0),
    salvage_value            numeric(19,4) NOT NULL DEFAULT 0 CHECK (salvage_value >= 0),
    cost_basis               numeric(19,4) NOT NULL CHECK (cost_basis >= 0),
    accumulated_depreciation numeric(19,4) NOT NULL DEFAULT 0 CHECK (accumulated_depreciation >= 0),
    net_book_value           numeric(19,4) GENERATED ALWAYS AS (cost_basis - accumulated_depreciation) STORED,
    created_at               timestamptz   NOT NULL DEFAULT now(),
    updated_at               timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (asset_id, book_type)
);

-- Asset Transactions (Depreciation, Revaluations, Impairments, Disposals)
CREATE TABLE asset_transactions (
    id                 uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id           uuid          NOT NULL REFERENCES fixed_assets(id),
    book_id            uuid          NOT NULL REFERENCES asset_books(id),
    business_event_id  uuid          NOT NULL REFERENCES business_events(id),
    transaction_type   varchar(20)   NOT NULL
                       CHECK (transaction_type IN ('CAPITALISATION','DEPRECIATION','IMPAIRMENT','REVALUATION','DISPOSAL')),
    transaction_date   date          NOT NULL,
    amount             numeric(19,4) NOT NULL,
    created_at         timestamptz   NOT NULL DEFAULT now()
);

-- AASB 16 Lease Contracts (Right-of-Use Assets & Lease Liabilities)
CREATE TABLE lease_contracts (
    id                    uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id             uuid          NOT NULL REFERENCES entities(id),
    lessor_party_id       uuid          NOT NULL REFERENCES parties(id),
    contract_number       varchar(100)  NOT NULL,
    commencement_date     date          NOT NULL,
    termination_date      date          NOT NULL,
    lease_term_months     integer       NOT NULL CHECK (lease_term_months > 0),
    discount_rate_pct     numeric(7,4)  NOT NULL CHECK (discount_rate_pct >= 0), -- Incremental Borrowing Rate (IBR)
    initial_rou_asset_val numeric(19,4) NOT NULL CHECK (initial_rou_asset_val > 0),
    initial_liability_val numeric(19,4) NOT NULL CHECK (initial_liability_val > 0),
    rou_asset_account_id  uuid          NOT NULL REFERENCES accounts(id), -- Non-Current Asset
    lease_liab_account_id uuid          NOT NULL REFERENCES accounts(id), -- Liability
    interest_account_id   uuid          NOT NULL REFERENCES accounts(id), -- Finance Expense
    workflow_status       varchar(20)   NOT NULL DEFAULT 'ACTIVE'
                          CHECK (workflow_status IN ('ACTIVE','MODIFIED','TERMINATED')),
    created_at            timestamptz   NOT NULL DEFAULT now(),
    CHECK (termination_date > commencement_date),
    UNIQUE (entity_id, contract_number)
);

-- Periodic Lease Amortisation Schedule Lines
CREATE TABLE lease_schedules (
    id                 uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    lease_id           uuid          NOT NULL REFERENCES lease_contracts(id) ON DELETE CASCADE,
    period_number      smallint      NOT NULL CHECK (period_number > 0),
    payment_date       date          NOT NULL,
    payment_amount     numeric(19,4) NOT NULL CHECK (payment_amount >= 0),
    principal_amount   numeric(19,4) NOT NULL CHECK (principal_amount >= 0),
    interest_amount    numeric(19,4) NOT NULL CHECK (interest_amount >= 0),
    rou_depreciation   numeric(19,4) NOT NULL CHECK (rou_depreciation >= 0),
    closing_liability  numeric(19,4) NOT NULL CHECK (closing_liability >= 0),
    is_posted          boolean       NOT NULL DEFAULT false,
    business_event_id  uuid          REFERENCES business_events(id),
    created_at         timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (lease_id, period_number)
);


-- =============================================================================
-- SECTION 3. PROJECTS, TIMESHEETS & CONTRACT WIP (DOMAIN 12 - AASB 15)
-- Professional services, construction contracts, timesheets & billing WIP.
-- =============================================================================

CREATE TABLE projects (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    customer_party_id    uuid          NOT NULL REFERENCES parties(id),
    code                 varchar(50)   NOT NULL,
    name                 varchar(200)  NOT NULL,
    billing_type         varchar(30)   NOT NULL
                         CHECK (billing_type IN ('TIME_AND_MATERIALS','FIXED_FEE','RETAINER','PROGRESS_CLAIM')),
    contract_value       numeric(19,4) DEFAULT 0 CHECK (contract_value >= 0),
    currency_code        char(3)       NOT NULL REFERENCES currencies(code),
    project_manager_id   uuid          REFERENCES users(id),
    start_date           date          NOT NULL,
    end_date             date,
    status               varchar(20)   NOT NULL DEFAULT 'ACTIVE'
                         CHECK (status IN ('PLANNING','ACTIVE','ON_HOLD','COMPLETED','CLOSED')),
    lock_version         integer       NOT NULL DEFAULT 1,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, code)
);

CREATE TABLE project_tasks (
    id            uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id    uuid         NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    code          varchar(50)  NOT NULL,
    name          varchar(200) NOT NULL,
    is_billable   boolean      NOT NULL DEFAULT true,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (project_id, code)
);

-- Internal Cost Rate vs External Billing Rate
CREATE TABLE project_rates (
    id             uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id     uuid          REFERENCES projects(id), -- NULL = Default global rate
    role_name      varchar(100)  NOT NULL,
    cost_rate_hr   numeric(19,4) NOT NULL CHECK (cost_rate_hr >= 0),
    bill_rate_hr   numeric(19,4) NOT NULL CHECK (bill_rate_hr >= 0),
    currency_code  char(3)       NOT NULL REFERENCES currencies(code),
    valid_from     date          NOT NULL DEFAULT DATE '1900-01-01',
    valid_to       date,
    created_at     timestamptz   NOT NULL DEFAULT now()
);

-- Timesheets (Labour Effort Capture)
CREATE TABLE timesheets (
    id            uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id     uuid         NOT NULL REFERENCES entities(id),
    user_id       uuid         NOT NULL REFERENCES users(id),
    week_start    date         NOT NULL,
    status        varchar(20)  NOT NULL DEFAULT 'DRAFT'
                  CHECK (status IN ('DRAFT','SUBMITTED','APPROVED','REJECTED')),
    approved_by   uuid         REFERENCES users(id),
    approved_at   timestamptz,
    created_at    timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (entity_id, user_id, week_start)
);

CREATE TABLE timesheet_lines (
    id             uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    timesheet_id   uuid          NOT NULL REFERENCES timesheets(id) ON DELETE CASCADE,
    project_id     uuid          NOT NULL REFERENCES projects(id),
    task_id        uuid          NOT NULL REFERENCES project_tasks(id),
    work_date      date          NOT NULL,
    hours_worked   numeric(5,2)  NOT NULL CHECK (hours_worked > 0 AND hours_worked <= 24),
    is_billable    boolean       NOT NULL DEFAULT true,
    cost_rate      numeric(19,4) NOT NULL DEFAULT 0,
    bill_rate      numeric(19,4) NOT NULL DEFAULT 0,
    total_cost     numeric(19,4) GENERATED ALWAYS AS (hours_worked * cost_rate) STORED,
    total_billable numeric(19,4) GENERATED ALWAYS AS (hours_worked * bill_rate) STORED,
    description    varchar(500)  NOT NULL,
    created_at     timestamptz   NOT NULL DEFAULT now()
);

-- Project WIP Ledger: Tracks accumulated costs and unbilled revenue (AASB 15 Contract Asset)
CREATE TABLE project_wip_entries (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    project_id           uuid          NOT NULL REFERENCES projects(id),
    business_event_id    uuid          NOT NULL REFERENCES business_events(id),
    source_type          varchar(20)   NOT NULL CHECK (source_type IN ('TIMESHEET','EXPENSE','AP_BILL','INVENTORY')),
    source_id            uuid          NOT NULL,
    cost_amount          numeric(19,4) NOT NULL DEFAULT 0,
    billable_amount      numeric(19,4) NOT NULL DEFAULT 0,
    is_billed            boolean       NOT NULL DEFAULT false,
    customer_invoice_id  uuid          REFERENCES customer_invoices(id),
    created_at           timestamptz   NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 4. PAYROLL INTEGRATION & HRIS CLEARING (DOMAIN 14)
-- Ingests gross summaries without storing sensitive PII in the core ERP.
-- =============================================================================

CREATE TABLE payroll_runs (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    external_system      varchar(50)   NOT NULL, -- 'EmploymentHero', 'KeyPay', 'Xero'
    external_run_id      varchar(100)  NOT NULL,
    pay_period_start     date          NOT NULL,
    pay_period_end       date          NOT NULL,
    payment_date         date          NOT NULL,
    gross_wages          numeric(19,4) NOT NULL CHECK (gross_wages >= 0),
    net_wages            numeric(19,4) NOT NULL CHECK (net_wages >= 0),
    payg_withholding     numeric(19,4) NOT NULL CHECK (payg_withholding >= 0),
    superannuation_sg    numeric(19,4) NOT NULL CHECK (superannuation_sg >= 0),
    total_employer_cost  numeric(19,4) GENERATED ALWAYS AS (gross_wages + superannuation_sg) STORED,
    workflow_status      varchar(20)   NOT NULL DEFAULT 'RECEIVED'
                         CHECK (workflow_status IN ('RECEIVED','VALIDATED','ACCOUNTED')),
    business_event_id    uuid          REFERENCES business_events(id),
    created_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, external_system, external_run_id)
);

CREATE TABLE payroll_cost_allocations (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    payroll_run_id       uuid          NOT NULL REFERENCES payroll_runs(id) ON DELETE CASCADE,
    dimension_set_id     uuid          NOT NULL REFERENCES dimension_sets(id), -- Dept / Project
    allocated_wages      numeric(19,4) NOT NULL CHECK (allocated_wages >= 0),
    allocated_super      numeric(19,4) NOT NULL CHECK (allocated_super >= 0),
    created_at           timestamptz   NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 5. TRIGGER WIRING & IMMUTABILITY ENFORCEMENT
-- =============================================================================

-- Immutability on movement logs and schedules
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'inventory_movements', 'inventory_cost_layers', 'asset_transactions',
        'lease_schedules', 'project_wip_entries']
    LOOP
        EXECUTE format('CREATE TRIGGER t_%s_immutable BEFORE UPDATE OR DELETE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_reject_mutation()', t, t);
        EXECUTE format('CREATE TRIGGER t_%s_no_truncate BEFORE TRUNCATE ON %I
                        FOR EACH STATEMENT EXECUTE FUNCTION trg_reject_mutation()', t, t);
    END LOOP;
END $$;

-- Audit logging on master data & assets
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'inventory_locations', 'inventory_cost_pools', 'fixed_assets',
        'asset_books', 'lease_contracts', 'projects', 'timesheets', 'payroll_runs']
    LOOP
        EXECUTE format('CREATE TRIGGER t_%s_audit AFTER INSERT OR UPDATE OR DELETE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_audit_row()', t, t);
    END LOOP;
END $$;


-- =============================================================================
-- SECTION 6. READ MODELS & WORKSPACE VIEWS
-- =============================================================================

-- Unbilled Project WIP for Billing Managers
CREATE OR REPLACE VIEW v_project_unbilled_wip AS
SELECT p.id AS project_id,
       p.entity_id,
       p.code AS project_code,
       p.name AS project_name,
       p.billing_type,
       cust.name AS customer_name,
       count(wip.id) AS unbilled_entry_count,
       sum(wip.cost_amount) AS total_unbilled_cost,
       sum(wip.billable_amount) AS total_unbilled_revenue
  FROM projects p
  JOIN parties cust ON cust.id = p.customer_party_id
  LEFT JOIN project_wip_entries wip ON wip.project_id = p.id AND NOT wip.is_billed
 WHERE p.status = 'ACTIVE'
 GROUP BY p.id, p.entity_id, p.code, p.name, p.billing_type, cust.name;

-- Asset Register Net Book Value Summary for Month-End FA Roll-Forward
CREATE OR REPLACE VIEW v_fixed_asset_summary AS
SELECT fa.id AS asset_id,
       fa.entity_id,
       fa.asset_number,
       fa.name AS asset_name,
       fa.acquisition_date,
       fa.in_service_date,
       ab.book_type,
       ab.depreciation_method,
       ab.useful_life_months,
       ab.cost_basis,
       ab.accumulated_depreciation,
       ab.net_book_value,
       acct_asset.code AS ppe_account_code,
       acct_deprec.code AS accum_deprec_code
  FROM fixed_assets fa
  JOIN asset_books ab ON ab.asset_id = fa.id
  JOIN accounts acct_asset ON acct_asset.id = ab.asset_account_id
  JOIN accounts acct_deprec ON acct_deprec.id = ab.accum_deprec_account_id
 WHERE fa.status IN ('IN_SERVICE','DRAFT');

-- ============================== END OF FILE ==================================

-- =============================================================================
-- FILE:    003_sales_purchasing_subledger.sql
-- SYSTEM:  HRT Systems (Radical TG) - Database Design v2 Migration 003
-- PURPOSE: Implements the operational document models and subledgers for:
--          1. Items, Units of Measure & Price Lists (Domain 5)
--          2. Sales & Accounts Receivable - Quote to Cash (Domain 6)
--          3. Procurement & Accounts Payable - Procure to Pay (Domain 7)
--          4. Automated 3-Way Matching & GRNI Clearing Engine
--          5. Australian Banking Association (ABA) Payment Batches
--          6. Universal Document Workflow & Approval Anchors (Domain 18)
--
-- DESIGN RATIONALE:
--   * Master Context Sections 163-174 (AP), 175-182 (AR), 135-145 (Workflow)
--   * SDLC_22 Architectural Rectification & SDLC_23 Complete Data Architecture
--   * Concurrency: lock_version integer on mutable drafts
--   * Immutability: Once APPROVED/ISSUED, documents freeze with document_hash
-- =============================================================================


-- =============================================================================
-- SECTION 1. ITEMS, UNITS OF MEASURE & PRICING (DOMAIN 5)
-- =============================================================================

-- Base and derived units of measure (e.g. EA, HR, KG, M, BOX)
CREATE TABLE units_of_measure (
    id          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    code        varchar(20)  NOT NULL UNIQUE, -- e.g. 'EA', 'KG', 'HR', 'BOX'
    name        varchar(100) NOT NULL,
    symbol      varchar(10)  NOT NULL,
    is_active   boolean      NOT NULL DEFAULT true,
    created_at  timestamptz  NOT NULL DEFAULT now()
);

-- Conversion multipliers between units (e.g. 1 BOX = 10 EA)
CREATE TABLE uom_conversions (
    id            uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    from_uom_id   uuid          NOT NULL REFERENCES units_of_measure(id),
    to_uom_id     uuid          NOT NULL REFERENCES units_of_measure(id),
    multiplier    numeric(18,8) NOT NULL CHECK (multiplier > 0),
    created_at    timestamptz   NOT NULL DEFAULT now(),
    CHECK (from_uom_id <> to_uom_id),
    UNIQUE (from_uom_id, to_uom_id)
);

-- Item reporting categories
CREATE TABLE item_categories (
    id                  uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    code                varchar(30)  NOT NULL UNIQUE,
    name                varchar(100) NOT NULL,
    parent_category_id  uuid         REFERENCES item_categories(id),
    is_active           boolean      NOT NULL DEFAULT true,
    created_at          timestamptz  NOT NULL DEFAULT now()
);

-- Item Master (Products, stock items, services, charges)
CREATE TABLE items (
    id                  uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    code                varchar(50)  NOT NULL UNIQUE,
    name                varchar(200) NOT NULL,
    item_type           varchar(20)  NOT NULL
                        CHECK (item_type IN ('STOCK','NON_STOCK','SERVICE','FIXED_ASSET')),
    base_uom_id         uuid         NOT NULL REFERENCES units_of_measure(id),
    category_id         uuid         REFERENCES item_categories(id),
    default_tax_code_id uuid         REFERENCES tax_codes(id),
    is_active           boolean      NOT NULL DEFAULT true,
    lock_version        integer      NOT NULL DEFAULT 1,
    created_at          timestamptz  NOT NULL DEFAULT now(),
    updated_at          timestamptz  NOT NULL DEFAULT now()
);

-- Item GL Posting Groups: links items to appropriate CoA accounts
CREATE TABLE item_posting_groups (
    id                          uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id                     uuid         NOT NULL UNIQUE REFERENCES items(id) ON DELETE RESTRICT,
    inventory_account_id        uuid         REFERENCES accounts(id), -- Asset (for STOCK)
    cogs_account_id             uuid         REFERENCES accounts(id), -- Expense (COGS upon sale)
    revenue_account_id          uuid         NOT NULL REFERENCES accounts(id), -- Revenue (Sales)
    expense_account_id          uuid         REFERENCES accounts(id), -- Expense (for NON_STOCK / Services)
    purchase_variance_account_id uuid        REFERENCES accounts(id), -- Purchase Price Variance (PPV)
    created_at                  timestamptz  NOT NULL DEFAULT now(),
    updated_at                  timestamptz  NOT NULL DEFAULT now()
);

-- Price lists (by currency, customer tier, or effective dates)
CREATE TABLE price_lists (
    id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    code           varchar(30)  NOT NULL UNIQUE,
    name           varchar(100) NOT NULL,
    currency_code  char(3)      NOT NULL REFERENCES currencies(code),
    is_active      boolean      NOT NULL DEFAULT true,
    created_at     timestamptz  NOT NULL DEFAULT now()
);

CREATE TABLE price_list_items (
    id             uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    price_list_id  uuid          NOT NULL REFERENCES price_lists(id),
    item_id        uuid          NOT NULL REFERENCES items(id),
    unit_price     numeric(19,4) NOT NULL CHECK (unit_price >= 0),
    min_quantity   numeric(19,4) NOT NULL DEFAULT 1 CHECK (min_quantity >= 0),
    valid_from     date          NOT NULL DEFAULT DATE '1900-01-01',
    valid_to       date,
    created_at     timestamptz   NOT NULL DEFAULT now(),
    CHECK (valid_to IS NULL OR valid_to >= valid_from),
    UNIQUE (price_list_id, item_id, min_quantity, valid_from)
);


-- =============================================================================
-- SECTION 2. SALES & ACCOUNTS RECEIVABLE (DOMAIN 6)
-- Quote -> Order -> Customer Invoice -> Credit Note -> Receipt -> Allocation
-- =============================================================================

-- Sales Orders (Commercial commitment & demand)
CREATE TABLE sales_orders (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    customer_party_id    uuid          NOT NULL REFERENCES parties(id),
    order_number         varchar(100)  NOT NULL,
    order_date           date          NOT NULL,
    currency_code        char(3)       NOT NULL REFERENCES currencies(code),
    exchange_rate        numeric(28,12) NOT NULL DEFAULT 1.0 CHECK (exchange_rate > 0),
    subtotal_amount      numeric(19,4) NOT NULL DEFAULT 0,
    tax_amount           numeric(19,4) NOT NULL DEFAULT 0,
    total_amount         numeric(19,4) NOT NULL DEFAULT 0,
    workflow_status      varchar(20)   NOT NULL DEFAULT 'DRAFT'
                         CHECK (workflow_status IN ('DRAFT','SUBMITTED','APPROVED','FULFILLED','CANCELLED')),
    lock_version         integer       NOT NULL DEFAULT 1,
    created_by           uuid          REFERENCES users(id),
    created_at           timestamptz   NOT NULL DEFAULT now(),
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, order_number)
);

CREATE TABLE sales_order_lines (
    id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id         uuid          NOT NULL REFERENCES sales_orders(id) ON DELETE CASCADE,
    line_number      smallint      NOT NULL CHECK (line_number > 0),
    item_id          uuid          NOT NULL REFERENCES items(id),
    description      varchar(500)  NOT NULL,
    quantity         numeric(19,4) NOT NULL CHECK (quantity > 0),
    uom_id           uuid          NOT NULL REFERENCES units_of_measure(id),
    unit_price       numeric(19,4) NOT NULL CHECK (unit_price >= 0),
    discount_amount  numeric(19,4) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    line_subtotal    numeric(19,4) NOT NULL,
    tax_code_id      uuid          NOT NULL REFERENCES tax_codes(id),
    tax_amount       numeric(19,4) NOT NULL,
    line_total       numeric(19,4) NOT NULL,
    dimension_set_id uuid          REFERENCES dimension_sets(id),
    created_at       timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (order_id, line_number)
);

-- Customer Invoices (Statutory Tax Invoices)
CREATE TABLE customer_invoices (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    customer_party_id    uuid          NOT NULL REFERENCES parties(id),
    sales_order_id       uuid          REFERENCES sales_orders(id),
    invoice_number       varchar(100)  NOT NULL,
    invoice_date         date          NOT NULL,
    due_date             date          NOT NULL CHECK (due_date >= invoice_date),
    currency_code        char(3)       NOT NULL REFERENCES currencies(code),
    exchange_rate        numeric(28,12) NOT NULL DEFAULT 1.0 CHECK (exchange_rate > 0),
    subtotal_amount      numeric(19,4) NOT NULL DEFAULT 0,
    tax_amount           numeric(19,4) NOT NULL DEFAULT 0,
    total_amount         numeric(19,4) NOT NULL DEFAULT 0 CHECK (total_amount > 0),
    workflow_status      varchar(20)   NOT NULL DEFAULT 'DRAFT'
                         CHECK (workflow_status IN ('DRAFT','SUBMITTED','APPROVED','ISSUED','VOIDED')),
    accounting_status    varchar(20)   NOT NULL DEFAULT 'PENDING_ACCOUNTING'
                         CHECK (accounting_status IN ('PENDING_ACCOUNTING','ACCOUNTED','FAILED')),
    settlement_status    varchar(20)   NOT NULL DEFAULT 'UNPAID'
                         CHECK (settlement_status IN ('UNPAID','PARTIALLY_PAID','PAID')),
    business_event_id    uuid          REFERENCES business_events(id),
    evidence_file_id     uuid          REFERENCES evidence_files(id),
    document_hash        bytea,        -- SHA-256 set upon approval/issue
    lock_version         integer       NOT NULL DEFAULT 1,
    issued_at            timestamptz,
    issued_by            uuid          REFERENCES users(id),
    created_at           timestamptz   NOT NULL DEFAULT now(),
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, invoice_number)
);

CREATE TABLE customer_invoice_lines (
    id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id       uuid          NOT NULL REFERENCES customer_invoices(id) ON DELETE RESTRICT,
    line_number      smallint      NOT NULL CHECK (line_number > 0),
    item_id          uuid          NOT NULL REFERENCES items(id),
    description      varchar(500)  NOT NULL,
    quantity         numeric(19,4) NOT NULL CHECK (quantity > 0),
    uom_id           uuid          NOT NULL REFERENCES units_of_measure(id),
    unit_price       numeric(19,4) NOT NULL CHECK (unit_price >= 0),
    discount_amount  numeric(19,4) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    line_subtotal    numeric(19,4) NOT NULL,
    tax_code_id      uuid          NOT NULL REFERENCES tax_codes(id),
    tax_amount       numeric(19,4) NOT NULL,
    line_total       numeric(19,4) NOT NULL,
    dimension_set_id uuid          NOT NULL REFERENCES dimension_sets(id),
    created_at       timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (invoice_id, line_number)
);

-- Credit Notes (Customer Returns / Adjustments)
CREATE TABLE credit_notes (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    customer_party_id    uuid          NOT NULL REFERENCES parties(id),
    invoice_id           uuid          REFERENCES customer_invoices(id),
    credit_note_number   varchar(100)  NOT NULL,
    credit_note_date     date          NOT NULL,
    currency_code        char(3)       NOT NULL REFERENCES currencies(code),
    exchange_rate        numeric(28,12) NOT NULL DEFAULT 1.0 CHECK (exchange_rate > 0),
    subtotal_amount      numeric(19,4) NOT NULL DEFAULT 0,
    tax_amount           numeric(19,4) NOT NULL DEFAULT 0,
    total_amount         numeric(19,4) NOT NULL DEFAULT 0 CHECK (total_amount > 0),
    reason_code          varchar(50)   NOT NULL,
    workflow_status      varchar(20)   NOT NULL DEFAULT 'DRAFT'
                         CHECK (workflow_status IN ('DRAFT','APPROVED','ISSUED','VOIDED')),
    accounting_status    varchar(20)   NOT NULL DEFAULT 'PENDING_ACCOUNTING'
                         CHECK (accounting_status IN ('PENDING_ACCOUNTING','ACCOUNTED','FAILED')),
    business_event_id    uuid          REFERENCES business_events(id),
    document_hash        bytea,
    lock_version         integer       NOT NULL DEFAULT 1,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, credit_note_number)
);

CREATE TABLE credit_note_lines (
    id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    credit_note_id   uuid          NOT NULL REFERENCES credit_notes(id) ON DELETE RESTRICT,
    line_number      smallint      NOT NULL CHECK (line_number > 0),
    item_id          uuid          NOT NULL REFERENCES items(id),
    description      varchar(500)  NOT NULL,
    quantity         numeric(19,4) NOT NULL CHECK (quantity > 0),
    uom_id           uuid          NOT NULL REFERENCES units_of_measure(id),
    unit_price       numeric(19,4) NOT NULL CHECK (unit_price >= 0),
    line_subtotal    numeric(19,4) NOT NULL,
    tax_code_id      uuid          NOT NULL REFERENCES tax_codes(id),
    tax_amount       numeric(19,4) NOT NULL,
    line_total       numeric(19,4) NOT NULL,
    dimension_set_id uuid          NOT NULL REFERENCES dimension_sets(id),
    created_at       timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (credit_note_id, line_number)
);

-- Customer Receipts (Incoming Cash from Customers)
CREATE TABLE customer_receipts (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    customer_party_id    uuid          NOT NULL REFERENCES parties(id),
    bank_account_id      uuid          NOT NULL REFERENCES bank_accounts(id),
    receipt_number       varchar(100)  NOT NULL,
    receipt_date         date          NOT NULL,
    currency_code        char(3)       NOT NULL REFERENCES currencies(code),
    exchange_rate        numeric(28,12) NOT NULL DEFAULT 1.0 CHECK (exchange_rate > 0),
    amount_received      numeric(19,4) NOT NULL CHECK (amount_received > 0),
    merchant_fee_amount  numeric(19,4) NOT NULL DEFAULT 0 CHECK (merchant_fee_amount >= 0),
    net_deposit_amount   numeric(19,4) GENERATED ALWAYS AS (amount_received - merchant_fee_amount) STORED,
    unapplied_balance    numeric(19,4) NOT NULL DEFAULT 0,
    payment_reference    varchar(255), -- Remittance advice, Stripe charge ID
    business_event_id    uuid          REFERENCES business_events(id),
    created_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, receipt_number)
);


-- =============================================================================
-- SECTION 3. PROCUREMENT & ACCOUNTS PAYABLE (DOMAIN 7)
-- Requisition -> PO -> Goods Receipt (GRNI) -> Supplier Invoice -> Payment Batch
-- =============================================================================

-- Purchase Orders (Legal commitment to suppliers)
CREATE TABLE purchase_orders (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    supplier_party_id    uuid          NOT NULL REFERENCES parties(id),
    po_number            varchar(100)  NOT NULL,
    po_date              date          NOT NULL,
    expected_date        date,
    currency_code        char(3)       NOT NULL REFERENCES currencies(code),
    exchange_rate        numeric(28,12) NOT NULL DEFAULT 1.0 CHECK (exchange_rate > 0),
    subtotal_amount      numeric(19,4) NOT NULL DEFAULT 0,
    tax_amount           numeric(19,4) NOT NULL DEFAULT 0,
    total_amount         numeric(19,4) NOT NULL DEFAULT 0,
    workflow_status      varchar(20)   NOT NULL DEFAULT 'DRAFT'
                         CHECK (workflow_status IN ('DRAFT','SUBMITTED','APPROVED','PARTIALLY_RECEIVED','RECEIVED','CLOSED','CANCELLED')),
    evidence_file_id     uuid          REFERENCES evidence_files(id),
    lock_version         integer       NOT NULL DEFAULT 1,
    document_hash        bytea,
    created_by           uuid          REFERENCES users(id),
    created_at           timestamptz   NOT NULL DEFAULT now(),
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, po_number)
);

CREATE TABLE purchase_order_lines (
    id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    po_id            uuid          NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
    line_number      smallint      NOT NULL CHECK (line_number > 0),
    item_id          uuid          NOT NULL REFERENCES items(id),
    description      varchar(500)  NOT NULL,
    quantity_ordered numeric(19,4) NOT NULL CHECK (quantity_ordered > 0),
    uom_id           uuid          NOT NULL REFERENCES units_of_measure(id),
    unit_price       numeric(19,4) NOT NULL CHECK (unit_price >= 0),
    line_subtotal    numeric(19,4) NOT NULL,
    tax_code_id      uuid          NOT NULL REFERENCES tax_codes(id),
    tax_amount       numeric(19,4) NOT NULL,
    line_total       numeric(19,4) NOT NULL,
    dimension_set_id uuid          REFERENCES dimension_sets(id),
    created_at       timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (po_id, line_number)
);

-- Goods Receipts (Delivery Note acknowledgement -> Posts GRNI Accrual)
-- Accounting Consequence: Dr Inventory / Expense, Cr GRNI Clearing Account
CREATE TABLE goods_receipts (
    id                   uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid         NOT NULL REFERENCES entities(id),
    supplier_party_id    uuid         NOT NULL REFERENCES parties(id),
    po_id                uuid         NOT NULL REFERENCES purchase_orders(id),
    receipt_number       varchar(100) NOT NULL,
    receipt_date         date         NOT NULL,
    delivery_reference   varchar(255), -- Supplier delivery docket
    evidence_file_id     uuid         REFERENCES evidence_files(id),
    business_event_id    uuid         REFERENCES business_events(id),
    created_by           uuid         REFERENCES users(id),
    created_at           timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (entity_id, receipt_number)
);

CREATE TABLE goods_receipt_lines (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    receipt_id           uuid          NOT NULL REFERENCES goods_receipts(id) ON DELETE RESTRICT,
    line_number          smallint      NOT NULL CHECK (line_number > 0),
    po_line_id           uuid          NOT NULL REFERENCES purchase_order_lines(id),
    item_id              uuid          NOT NULL REFERENCES items(id),
    quantity_received    numeric(19,4) NOT NULL CHECK (quantity_received > 0),
    quantity_rejected    numeric(19,4) NOT NULL DEFAULT 0 CHECK (quantity_rejected >= 0),
    uom_id               uuid          NOT NULL REFERENCES units_of_measure(id),
    unit_cost            numeric(19,4) NOT NULL CHECK (unit_cost >= 0),
    total_cost           numeric(19,4) NOT NULL,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (receipt_id, line_number)
);

-- Supplier Invoices (Bills)
-- Accounting Consequence: Dr GRNI Clearing, Dr GST Receivable, Cr Accounts Payable
CREATE TABLE supplier_invoices (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    supplier_party_id    uuid          NOT NULL REFERENCES parties(id),
    po_id                uuid          REFERENCES purchase_orders(id),
    invoice_number       varchar(100)  NOT NULL, -- Supplier's own invoice reference
    bill_date            date          NOT NULL,
    due_date             date          NOT NULL CHECK (due_date >= bill_date),
    currency_code        char(3)       NOT NULL REFERENCES currencies(code),
    exchange_rate        numeric(28,12) NOT NULL DEFAULT 1.0 CHECK (exchange_rate > 0),
    subtotal_amount      numeric(19,4) NOT NULL DEFAULT 0,
    tax_amount           numeric(19,4) NOT NULL DEFAULT 0,
    total_amount         numeric(19,4) NOT NULL DEFAULT 0 CHECK (total_amount > 0),
    match_status         varchar(30)   NOT NULL DEFAULT 'UNMATCHED'
                         CHECK (match_status IN ('UNMATCHED','2_WAY_MATCHED','3_WAY_MATCHED','VARIANCE_APPROVED')),
    workflow_status      varchar(20)   NOT NULL DEFAULT 'DRAFT'
                         CHECK (workflow_status IN ('DRAFT','SUBMITTED','APPROVED','VOIDED')),
    accounting_status    varchar(20)   NOT NULL DEFAULT 'PENDING_ACCOUNTING'
                         CHECK (accounting_status IN ('PENDING_ACCOUNTING','ACCOUNTED','FAILED')),
    settlement_status    varchar(20)   NOT NULL DEFAULT 'UNPAID'
                         CHECK (settlement_status IN ('UNPAID','PARTIALLY_PAID','PAID')),
    business_event_id    uuid          REFERENCES business_events(id),
    evidence_file_id     uuid          REFERENCES evidence_files(id),
    document_hash        bytea,
    lock_version         integer       NOT NULL DEFAULT 1,
    approved_by          uuid          REFERENCES users(id),
    approved_at          timestamptz,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    updated_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, supplier_party_id, invoice_number)
);

CREATE TABLE supplier_invoice_lines (
    id                  uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id          uuid          NOT NULL REFERENCES supplier_invoices(id) ON DELETE RESTRICT,
    line_number         smallint      NOT NULL CHECK (line_number > 0),
    po_line_id          uuid          REFERENCES purchase_order_lines(id),
    goods_receipt_line_id uuid        REFERENCES goods_receipt_lines(id),
    item_id             uuid          NOT NULL REFERENCES items(id),
    description         varchar(500)  NOT NULL,
    quantity            numeric(19,4) NOT NULL CHECK (quantity > 0),
    uom_id              uuid          NOT NULL REFERENCES units_of_measure(id),
    unit_price          numeric(19,4) NOT NULL CHECK (unit_price >= 0),
    line_subtotal       numeric(19,4) NOT NULL,
    tax_code_id         uuid          NOT NULL REFERENCES tax_codes(id),
    tax_amount          numeric(19,4) NOT NULL,
    line_total          numeric(19,4) NOT NULL,
    dimension_set_id    uuid          NOT NULL REFERENCES dimension_sets(id),
    created_at          timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (invoice_id, line_number)
);

-- Supplier Credit Notes (Vendor Credits)
CREATE TABLE supplier_credit_notes (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    supplier_party_id    uuid          NOT NULL REFERENCES parties(id),
    credit_note_number   varchar(100)  NOT NULL,
    credit_date          date          NOT NULL,
    currency_code        char(3)       NOT NULL REFERENCES currencies(code),
    exchange_rate        numeric(28,12) NOT NULL DEFAULT 1.0 CHECK (exchange_rate > 0),
    subtotal_amount      numeric(19,4) NOT NULL DEFAULT 0,
    tax_amount           numeric(19,4) NOT NULL DEFAULT 0,
    total_amount         numeric(19,4) NOT NULL DEFAULT 0 CHECK (total_amount > 0),
    workflow_status      varchar(20)   NOT NULL DEFAULT 'DRAFT'
                         CHECK (workflow_status IN ('DRAFT','APPROVED','VOIDED')),
    business_event_id    uuid          REFERENCES business_events(id),
    evidence_file_id     uuid          REFERENCES evidence_files(id),
    created_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (entity_id, supplier_party_id, credit_note_number)
);


-- =============================================================================
-- SECTION 4. AUSTRALIAN BANKING ASSOCIATION (ABA) PAYMENT DISBURSEMENTS
-- Groups approved AP bills into ABA files for batch direct credit bank upload.
-- =============================================================================

CREATE TABLE payment_batches (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id            uuid          NOT NULL REFERENCES entities(id),
    bank_account_id      uuid          NOT NULL REFERENCES bank_accounts(id),
    batch_reference      varchar(50)   NOT NULL, -- e.g. 'PAY-2026-10-15'
    execution_date       date          NOT NULL,
    currency_code        char(3)       NOT NULL DEFAULT 'AUD' REFERENCES currencies(code),
    total_amount         numeric(19,4) NOT NULL DEFAULT 0,
    item_count           integer       NOT NULL DEFAULT 0,
    aba_file_content     text,         -- Formatted ABA string
    status               varchar(20)   NOT NULL DEFAULT 'PROPOSED'
                         CHECK (status IN ('PROPOSED','APPROVED','SUBMITTED','SETTLED','REJECTED')),
    created_by           uuid          NOT NULL REFERENCES users(id),
    approved_by          uuid          REFERENCES users(id),
    approved_at          timestamptz,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    -- SoD Fraud Invariant: Releaser must differ from batch creator
    CHECK (status <> 'APPROVED' OR (approved_by IS NOT NULL AND approved_by <> created_by))
);

CREATE TABLE payment_batch_items (
    id                   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id             uuid          NOT NULL REFERENCES payment_batches(id) ON DELETE CASCADE,
    supplier_party_id    uuid          NOT NULL REFERENCES parties(id),
    supplier_invoice_id  uuid          NOT NULL REFERENCES supplier_invoices(id),
    party_bank_account_id uuid         NOT NULL REFERENCES party_bank_accounts(id),
    payment_amount       numeric(19,4) NOT NULL CHECK (payment_amount > 0),
    remittance_reference varchar(18)   NOT NULL, -- 18 chars max for ABA format
    created_at           timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (batch_id, supplier_invoice_id)
);


-- =============================================================================
-- SECTION 5. DOCUMENT WORKFLOW & IMMUTABILITY GUARDS
-- Freezes approved documents: once an invoice or bill is APPROVED or ISSUED,
-- it can NEVER be updated or deleted. Corrections require credit notes.
-- =============================================================================

CREATE OR REPLACE FUNCTION trg_freeze_operational_document() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $$
BEGIN
    -- If document was already approved/issued, block any content mutations
    IF OLD.workflow_status IN ('APPROVED','ISSUED','FULFILLED','VOIDED') THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'HRT-DOC-001: % % is approved/issued and cannot be deleted',
                TG_TABLE_NAME, OLD.id;
        END IF;

        -- Allow only settlement_status and accounting_status transitions
        IF (NEW.subtotal_amount, NEW.tax_amount, NEW.total_amount, NEW.currency_code)
           IS DISTINCT FROM
           (OLD.subtotal_amount, OLD.tax_amount, OLD.total_amount, OLD.currency_code) THEN
            RAISE EXCEPTION 'HRT-DOC-002: % % is frozen; financial values cannot be edited. Issue a Credit Note instead.',
                TG_TABLE_NAME, OLD.id;
        END IF;
    END IF;

    -- On first transition to APPROVED or ISSUED, generate cryptographic document hash
    IF NEW.workflow_status IN ('APPROVED','ISSUED') AND OLD.workflow_status NOT IN ('APPROVED','ISSUED') THEN
        NEW.document_hash := sha256(convert_to(
            format('%s|%s|%s|%s|%s', NEW.id, NEW.entity_id, NEW.total_amount, NEW.currency_code, now()),
            'UTF8'
        ));
    END IF;

    -- Bump lock version on successful modification
    NEW.lock_version := OLD.lock_version + 1;
    NEW.updated_at   := now();
    RETURN NEW;
END $$;

CREATE TRIGGER t_customer_invoices_freeze
    BEFORE UPDATE OR DELETE ON customer_invoices
    FOR EACH ROW EXECUTE FUNCTION trg_freeze_operational_document();

CREATE TRIGGER t_supplier_invoices_freeze
    BEFORE UPDATE OR DELETE ON supplier_invoices
    FOR EACH ROW EXECUTE FUNCTION trg_freeze_operational_document();

CREATE TRIGGER t_credit_notes_freeze
    BEFORE UPDATE OR DELETE ON credit_notes
    FOR EACH ROW EXECUTE FUNCTION trg_freeze_operational_document();


-- =============================================================================
-- SECTION 6. TRIGGER WIRING & AUDIT LOGGING
-- =============================================================================

-- Immutability on execution lines
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'goods_receipts', 'goods_receipt_lines', 'customer_receipts',
        'payment_batch_items']
    LOOP
        EXECUTE format('CREATE TRIGGER t_%s_immutable BEFORE UPDATE OR DELETE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_reject_mutation()', t, t);
        EXECUTE format('CREATE TRIGGER t_%s_no_truncate BEFORE TRUNCATE ON %I
                        FOR EACH STATEMENT EXECUTE FUNCTION trg_reject_mutation()', t, t);
    END LOOP;
END $$;

-- Audit logging on operational master records & headers
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'units_of_measure', 'uom_conversions', 'item_categories', 'items',
        'item_posting_groups', 'price_lists', 'sales_orders', 'customer_invoices',
        'credit_notes', 'purchase_orders', 'supplier_invoices', 'payment_batches']
    LOOP
        EXECUTE format('CREATE TRIGGER t_%s_audit AFTER INSERT OR UPDATE OR DELETE ON %I
                        FOR EACH ROW EXECUTE FUNCTION trg_audit_row()', t, t);
    END LOOP;
END $$;


-- =============================================================================
-- SECTION 7. READ MODELS & WORKFLOW VIEWS
-- =============================================================================

-- 3-Way Match Verification View for AP Controllers
CREATE OR REPLACE VIEW v_ap_match_verification AS
SELECT po.po_number,
       si.invoice_number,
       p.name AS supplier_name,
       pol.line_number AS po_line_no,
       i.code AS item_code,
       pol.quantity_ordered,
       COALESCE(grl.quantity_received, 0) AS quantity_received,
       sil.quantity AS quantity_invoiced,
       pol.unit_price AS po_unit_price,
       sil.unit_price AS invoice_unit_price,
       (sil.unit_price - pol.unit_price) * sil.quantity AS price_variance,
       CASE
           WHEN grl.id IS NULL THEN 'MISSING_RECEIPT'
           WHEN sil.quantity > grl.quantity_received THEN 'QTY_OVER_INVOICED'
           WHEN sil.unit_price > pol.unit_price THEN 'PRICE_VARIANCE'
           ELSE 'MATCH_OK'
       END AS match_status
  FROM supplier_invoice_lines sil
  JOIN supplier_invoices si         ON si.id = sil.invoice_id
  JOIN parties p                    ON p.id = si.supplier_party_id
  LEFT JOIN purchase_order_lines pol ON pol.id = sil.po_line_id
  LEFT JOIN purchase_orders po      ON po.id = pol.po_id
  LEFT JOIN goods_receipt_lines grl  ON grl.id = sil.goods_receipt_line_id
  LEFT JOIN items i                 ON i.id = sil.item_id;

-- AR Aging Summary for Collections & Credit Management
CREATE OR REPLACE VIEW v_ar_aging_summary AS
SELECT oi.entity_id,
       p.id AS customer_party_id,
       p.code AS customer_code,
       p.name AS customer_name,
       oi.currency_code,
       sum(oi.original_amount - COALESCE(alloc.allocated_amount, 0)) AS total_outstanding,
       sum(CASE WHEN CURRENT_DATE <= oi.due_date 
                THEN (oi.original_amount - COALESCE(alloc.allocated_amount, 0)) ELSE 0 END) AS current_amount,
       sum(CASE WHEN CURRENT_DATE > oi.due_date AND CURRENT_DATE <= oi.due_date + 30 
                THEN (oi.original_amount - COALESCE(alloc.allocated_amount, 0)) ELSE 0 END) AS days_1_30,
       sum(CASE WHEN CURRENT_DATE > oi.due_date + 30 AND CURRENT_DATE <= oi.due_date + 60 
                THEN (oi.original_amount - COALESCE(alloc.allocated_amount, 0)) ELSE 0 END) AS days_31_60,
       sum(CASE WHEN CURRENT_DATE > oi.due_date + 60 AND CURRENT_DATE <= oi.due_date + 90 
                THEN (oi.original_amount - COALESCE(alloc.allocated_amount, 0)) ELSE 0 END) AS days_61_90,
       sum(CASE WHEN CURRENT_DATE > oi.due_date + 90 
                THEN (oi.original_amount - COALESCE(alloc.allocated_amount, 0)) ELSE 0 END) AS days_90_plus
  FROM open_items oi
  JOIN parties p ON p.id = oi.party_id
  LEFT JOIN (
      SELECT open_item_id, sum(amount) AS allocated_amount
        FROM open_item_allocations
       GROUP BY open_item_id
  ) alloc ON alloc.open_item_id = oi.id
 WHERE oi.item_type = 'AR'
   AND (oi.original_amount - COALESCE(alloc.allocated_amount, 0)) <> 0
 GROUP BY oi.entity_id, p.id, p.code, p.name, oi.currency_code;

-- ============================== END OF FILE ==================================

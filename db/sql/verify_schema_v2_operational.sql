-- =============================================================================
-- FILE:    verify_schema_v2_operational.sql
-- SYSTEM:  HRT Systems (Radical TG) - Verification for Migration 002
-- PURPOSE: Tests that Migration 002 enforces the operational and accounting
--          invariants for Control Events, Multi-Role Party, Banking, Tax, and
--          Credit Notes.
-- =============================================================================

DO $$
DECLARE
    v_user1_id           uuid := gen_random_uuid();
    v_user2_id           uuid := gen_random_uuid();
    v_entity_id          uuid := gen_random_uuid();
    v_ledger_id          uuid := gen_random_uuid();
    v_period_id          uuid := gen_random_uuid();
    v_party_id           uuid := gen_random_uuid();
    v_bank_gl_acct_id    uuid := gen_random_uuid();
    v_clearing_acct_id   uuid := gen_random_uuid();
    v_bank_acct_id       uuid := gen_random_uuid();
    v_statement_id       uuid := gen_random_uuid();
    v_stmt_line_id       uuid := gen_random_uuid();
    v_rec_session_id     uuid := gen_random_uuid();
    v_tax_code_id        uuid := gen_random_uuid();
    v_be_id              uuid := gen_random_uuid();
    v_ce_id              uuid := gen_random_uuid();
    v_bank_req_id        uuid := gen_random_uuid();
    v_credit_item_id     uuid := gen_random_uuid();
    v_alloc_be_id        uuid := gen_random_uuid();
BEGIN
    RAISE NOTICE '--- Starting Migration 002 Verification ---';

    -- 1. Setup seed users, entity, period
    INSERT INTO users (id, email, display_name, is_active)
    VALUES (v_user1_id, 'cfo@company.com', 'CFO User', true),
           (v_user2_id, 'controller@company.com', 'Financial Controller', true);

    INSERT INTO entities (id, code, legal_name, base_currency, country_code, is_active)
    VALUES (v_entity_id, 'AU01', 'Operating Pty Ltd', 'AUD', 'AU', true);

    INSERT INTO ledgers (id, code, name, ledger_type, accounting_framework, entity_id, ledger_currency, is_active)
    VALUES (v_ledger_id, 'MAIN_AU', 'Statutory Ledger', 'PRIMARY', 'AASB', v_entity_id, 'AUD', true);

    INSERT INTO accounting_periods (id, entity_id, fiscal_year, period_number, period_name, period_type, start_date, end_date, status)
    VALUES (v_period_id, v_entity_id, 2026, 1, '2026-Q1', 'REGULAR', '2026-07-01', '2026-09-30', 'OPEN');

    -- 2. Test Control Events (Immutable Governance Log)
    INSERT INTO control_events (
        id, entity_id, event_type, source_object_type, source_object_id,
        occurred_at, actor_id, idempotency_key, payload
    ) VALUES (
        v_ce_id, v_entity_id, 'AccountingPeriodClosed', 'AccountingPeriod', v_period_id,
        now(), v_user1_id, 'ce-test-key-1', '{"reason": "Month end closed"}'::jsonb
    );

    -- Confirm control event cannot be mutated
    BEGIN
        UPDATE control_events SET payload = '{"tampered": true}'::jsonb WHERE id = v_ce_id;
        RAISE EXCEPTION 'TEST FAILED: control_events update should have been blocked';
    EXCEPTION
        WHEN restrict_violation THEN
            RAISE NOTICE 'SUCCESS: control_events immutability trigger blocked UPDATE';
    END;

    -- 3. Test Universal Multi-Role Party
    INSERT INTO parties (id, party_type, code, name, default_currency, is_active)
    VALUES (v_party_id, 'CUSTOMER', 'PTY-ACME', 'Acme Trading & Supplies', 'AUD', true);

    -- Add multiple active roles to the SAME party
    INSERT INTO party_roles (party_id, role_type) VALUES (v_party_id, 'CUSTOMER');
    INSERT INTO party_roles (party_id, role_type) VALUES (v_party_id, 'SUPPLIER');

    INSERT INTO party_profiles (party_id, role_type, payment_terms_days, credit_limit)
    VALUES (v_party_id, 'CUSTOMER', 14, 50000.00),
           (v_party_id, 'SUPPLIER', 30, NULL);

    -- Add statutory tax registration (ABN)
    INSERT INTO party_tax_registrations (party_id, tax_id_type, registration_number, country_code, is_gst_registered, valid_from)
    VALUES (v_party_id, 'ABN', '12345678901', 'AU', true, '2020-01-01');

    RAISE NOTICE 'SUCCESS: Multi-Role Party (Customer + Supplier) registered';

    -- 4. Test Anti-Fraud Dual Authorization on Supplier Bank Accounts
    -- Self-approval should FAIL
    BEGIN
        INSERT INTO bank_account_change_requests (
            id, party_id, action, status, requested_by, approved_by, approved_at, reason
        ) VALUES (
            v_bank_req_id, v_party_id, 'CREATE', 'APPROVED', v_user1_id, v_user1_id, now(), 'Self-approving bank update'
        );
        RAISE EXCEPTION 'TEST FAILED: Self-approval of bank account change should be rejected by constraint';
    EXCEPTION
        WHEN check_violation THEN
            RAISE NOTICE 'SUCCESS: Dual authorization check blocked self-approval of bank account change';
    END;

    -- Proper dual authorization by a different user should SUCCEED
    INSERT INTO bank_account_change_requests (
        id, party_id, action, status, requested_by, approved_by, approved_at, reason
    ) VALUES (
        v_bank_req_id, v_party_id, 'CREATE', 'APPROVED', v_user1_id, v_user2_id, now(), 'Verified by phone call with supplier CFO'
    );
    RAISE NOTICE 'SUCCESS: Dual authorization accepted by distinct approver';

    -- 5. Test Banking Subledger & Statement Reconciliation
    INSERT INTO accounts (id, code, name, account_type, is_postable, is_control_account, is_active)
    VALUES (v_bank_gl_acct_id, '1010', 'Operating Bank Account', 'ASSET', true, false, true),
           (v_clearing_acct_id, '1020', 'Payment Clearing Account', 'ASSET', true, false, true);

    INSERT INTO bank_accounts (
        id, entity_id, code, name, bank_name, bsb, account_number, currency_code,
        gl_account_id, gl_clearing_account_id, is_active
    ) VALUES (
        v_bank_acct_id, v_entity_id, 'CBA-MAIN', 'Commonwealth Bank Operating', 'CBA', '062-000', '12345678', 'AUD',
        v_bank_gl_acct_id, v_clearing_acct_id, true
    );

    INSERT INTO bank_statements (
        id, bank_account_id, statement_identifier, opening_balance, closing_balance,
        start_date, end_date, status
    ) VALUES (
        v_statement_id, v_bank_acct_id, 'FEED-2026-07-01', 10000.00, 15000.00,
        '2026-07-01', '2026-07-01', 'OPEN'
    );

    INSERT INTO bank_statement_lines (
        id, statement_id, line_number, transaction_date, amount, external_reference, counterparty_name, description
    ) VALUES (
        v_stmt_line_id, v_statement_id, 1, '2026-07-01', 5000.00, 'TXN-987654', 'Acme Customer', 'Payment for INV-001'
    );

    -- Statement lines must be immutable
    BEGIN
        UPDATE bank_statement_lines SET amount = 6000.00 WHERE id = v_stmt_line_id;
        RAISE EXCEPTION 'TEST FAILED: bank_statement_lines update should be rejected';
    EXCEPTION
        WHEN restrict_violation THEN
            RAISE NOTICE 'SUCCESS: bank_statement_lines immutability trigger blocked UPDATE';
    END;

    -- 6. Test Tax Subledger & BAS Labels
    INSERT INTO tax_codes (id, code, name, jurisdiction, tax_type, is_active)
    VALUES (v_tax_code_id, 'GST-INCOME', 'GST 10% on Taxable Sales', 'AU', 'GST', true);

    INSERT INTO business_events (
        id, entity_id, event_type, source_object_type, source_object_id,
        idempotency_key, payload, payload_sha256, occurred_at
    ) VALUES (
        v_be_id, v_entity_id, 'CustomerInvoiceIssued', 'CustomerInvoice', gen_random_uuid(),
        'inv-be-key-1', '{}'::jsonb, '\x04', '2026-07-01 10:00:00Z'
    );

    INSERT INTO tax_lines (
        entity_id, business_event_id, tax_code_id, tax_date,
        taxable_amount, tax_amount, recoverable_percentage, bas_label
    ) VALUES (
        v_entity_id, v_be_id, v_tax_code_id, '2026-07-01',
        10000.00, 1000.00, 100.00, 'G1'
    );

    -- Tax lines must be immutable
    BEGIN
        UPDATE tax_lines SET tax_amount = 900.00 WHERE business_event_id = v_be_id;
        RAISE EXCEPTION 'TEST FAILED: tax_lines update should be rejected';
    EXCEPTION
        WHEN restrict_violation THEN
            RAISE NOTICE 'SUCCESS: tax_lines immutability trigger blocked UPDATE';
    END;

    -- 7. Test Negative Open Items (Credit Notes)
    INSERT INTO open_items (
        id, entity_id, party_id, item_type, business_event_id,
        document_number, currency_code, original_amount, document_date, due_date
    ) VALUES (
        v_credit_item_id, v_entity_id, v_party_id, 'AR', v_be_id,
        'CRN-2026-001', 'AUD', -2000.00, '2026-07-02', '2026-07-02'
    );

    INSERT INTO business_events (
        id, entity_id, event_type, source_object_type, source_object_id,
        idempotency_key, payload, payload_sha256, occurred_at
    ) VALUES (
        v_alloc_be_id, v_entity_id, 'PaymentAllocated', 'Allocation', gen_random_uuid(),
        'alloc-be-key-1', '{}'::jsonb, '\x05', '2026-07-02 12:00:00Z'
    );

    -- Allocate -500 against -2000 credit note
    INSERT INTO open_item_allocations (
        open_item_id, allocation_business_event_id, amount, allocated_on
    ) VALUES (
        v_credit_item_id, v_alloc_be_id, -500.00, '2026-07-02'
    );

    RAISE NOTICE 'SUCCESS: Negative open item (Credit Note) allocated successfully';

    RAISE NOTICE '--- All Migration 002 Verification Checks Passed ---';
END $$;

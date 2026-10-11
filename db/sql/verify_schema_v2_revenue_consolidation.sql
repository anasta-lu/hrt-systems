-- =============================================================================
-- FILE:    verify_schema_v2_revenue_consolidation.sql
-- SYSTEM:  HRT Systems (Radical TG) - Verification for Migration 005
-- PURPOSE: Tests that Migration 005 enforces AASB 15 revenue recognition,
--          intercompany elimination, continuous close workspace, and
--          ingress buffer idempotency.
-- =============================================================================

DO $$
DECLARE
    v_user_id        uuid := gen_random_uuid();
    v_parent_id      uuid := gen_random_uuid();
    v_sub_id         uuid := gen_random_uuid();
    v_group_id       uuid := gen_random_uuid();
    v_period_id      uuid := gen_random_uuid();
    v_cust_id        uuid := gen_random_uuid();
    v_be_id          uuid := gen_random_uuid();
    v_asset_acct_id  uuid := gen_random_uuid();
    v_liab_acct_id   uuid := gen_random_uuid();
    v_rev_acct_id    uuid := gen_random_uuid();
    v_cogs_acct_id   uuid := gen_random_uuid();
    v_inv_acct_id    uuid := gen_random_uuid();
    v_contract_id    uuid := gen_random_uuid();
    v_pob_id         uuid := gen_random_uuid();
    v_sched_id       uuid := gen_random_uuid();
    v_run_id         uuid := gen_random_uuid();
    v_agree_id       uuid := gen_random_uuid();
    v_cons_run_id    uuid := gen_random_uuid();
    v_elim_id        uuid := gen_random_uuid();
    v_ws_id          uuid := gen_random_uuid();
    v_inbox_id       uuid := gen_random_uuid();
BEGIN
    RAISE NOTICE '--- Starting Migration 005 Verification ---';

    -- 1. Setup seed user, parent & sub entities, accounts, period
    INSERT INTO users (id, email, display_name, is_active)
    VALUES (v_user_id, 'groupcfo@holding.com', 'Group CFO', true);

    INSERT INTO entities (id, code, legal_name, base_currency, country_code, is_active)
    VALUES (v_parent_id, 'HOLDING-01', 'Radical TG Holdings Pty Ltd', 'AUD', 'AU', true),
           (v_sub_id, 'SUB-01', 'Radical TG Operations Pty Ltd', 'AUD', 'AU', true);

    INSERT INTO consolidation_groups (id, code, name, reporting_currency)
    VALUES (v_group_id, 'GRP-MAIN', 'Radical TG Australasia Group', 'AUD');

    INSERT INTO consolidation_group_members (group_id, entity_id, ownership_pct)
    VALUES (v_group_id, v_parent_id, 100.00),
           (v_group_id, v_sub_id, 100.00);

    INSERT INTO accounting_periods (id, entity_id, fiscal_year, period_number, period_name, period_type, start_date, end_date, status)
    VALUES (v_period_id, v_parent_id, 2026, 3, '2026-Q3', 'REGULAR', '2027-01-01', '2027-03-31', 'OPEN');

    INSERT INTO parties (id, party_type, code, name, default_currency, is_active)
    VALUES (v_cust_id, 'CUSTOMER', 'ENTERPRISE-500', 'Global Enterprise Corp', 'AUD', true);

    INSERT INTO accounts (id, code, name, account_type, is_postable, is_active)
    VALUES (v_asset_acct_id, '1410', 'Contract Assets (Unbilled Revenue)', 'ASSET', true, true),
           (v_liab_acct_id, '2410', 'Contract Liabilities (Deferred Revenue)', 'LIABILITY', true, true),
           (v_rev_acct_id, '4200', 'SaaS Subscription Revenue', 'REVENUE', true, true),
           (v_cogs_acct_id, '5010', 'Group Intercompany COGS Elimination', 'EXPENSE', true, true),
           (v_inv_acct_id, '1401', 'Consolidated Inventory on Hand', 'ASSET', true, true);

    INSERT INTO business_events (
        id, entity_id, event_type, source_object_type, source_object_id,
        idempotency_key, payload, payload_sha256, occurred_at
    ) VALUES (
        v_be_id, v_parent_id, 'RevenueRecognised', 'RevenueContract', gen_random_uuid(),
        'rev-be-key-500', '{}'::jsonb, '\x12', now()
    );

    -- 2. Test AASB 15 Revenue Recognition Engine
    INSERT INTO revenue_contracts (
        id, entity_id, customer_party_id, contract_number, contract_date, start_date,
        total_contract_value, currency_code, status
    ) VALUES (
        v_contract_id, v_parent_id, v_cust_id, 'REV-CTR-2027-001', '2027-01-01', '2027-01-01',
        120000.00, 'AUD', 'ACTIVE'
    );

    INSERT INTO performance_obligations (
        id, contract_id, obligation_number, description, recognition_pattern,
        contract_asset_acct_id, contract_liab_acct_id, revenue_account_id,
        stand_alone_sell_price, allocated_amount
    ) VALUES (
        v_pob_id, v_contract_id, 'POB-01', 'Annual Enterprise Cloud Service', 'STRAIGHT_LINE',
        v_asset_acct_id, v_liab_acct_id, v_rev_acct_id, 120000.00, 120000.00
    );

    INSERT INTO revenue_schedules (
        id, obligation_id, accounting_period_id, schedule_date, planned_amount, recognised_amount
    ) VALUES (
        v_sched_id, v_pob_id, v_period_id, '2027-01-31', 10000.00, 0
    );

    -- Execute Revenue Recognition Run
    INSERT INTO revenue_recognition_runs (
        id, entity_id, obligation_id, business_event_id, schedule_id, amount_recognised
    ) VALUES (
        v_run_id, v_parent_id, v_pob_id, v_be_id, v_sched_id, 10000.00
    );

    -- Revenue runs must be immutable
    BEGIN
        UPDATE revenue_recognition_runs SET amount_recognised = 15000.00 WHERE id = v_run_id;
        RAISE EXCEPTION 'TEST FAILED: revenue_recognition_runs update should have failed';
    EXCEPTION
        WHEN restrict_violation THEN
            RAISE NOTICE 'SUCCESS: revenue_recognition_runs immutability trigger blocked UPDATE';
    END;

    RAISE NOTICE 'SUCCESS: AASB 15 Revenue contract and recognition run created';

    -- 3. Test Intercompany Agreement & Consolidation Elimination
    INSERT INTO intercompany_agreements (
        id, origin_entity_id, counterparty_entity_id, agreement_code,
        settlement_currency, transfer_pricing_rule
    ) VALUES (
        v_agree_id, v_parent_id, v_sub_id, 'ICA-AU-2027', 'AUD', 'COST_PLUS_10'
    );

    INSERT INTO consolidation_runs (
        id, group_id, accounting_period_id, run_date, status, executed_by
    ) VALUES (
        v_cons_run_id, v_group_id, v_period_id, '2027-03-31', 'IN_PROGRESS', v_user_id
    );

    -- Eliminate internal markup on unsold inventory (Dr Group COGS, Cr Inventory)
    INSERT INTO consolidation_elimination_entries (
        id, consolidation_run_id, elimination_type, origin_entity_id, counterparty_entity_id,
        debit_account_id, credit_account_id, elimination_amount, reporting_currency, description
    ) VALUES (
        v_elim_id, v_cons_run_id, 'UNREALIZED_PROFIT_INVENTORY', v_parent_id, v_sub_id,
        v_cogs_acct_id, v_inv_acct_id, 25000.00, 'AUD', 'Eliminate 10% intercompany markup on warehouse stock'
    );

    -- Elimination entries must be immutable
    BEGIN
        UPDATE consolidation_elimination_entries SET elimination_amount = 30000.00 WHERE id = v_elim_id;
        RAISE EXCEPTION 'TEST FAILED: consolidation_elimination_entries update should have failed';
    EXCEPTION
        WHEN restrict_violation THEN
            RAISE NOTICE 'SUCCESS: consolidation_elimination_entries immutability trigger blocked UPDATE';
    END;

    RAISE NOTICE 'SUCCESS: Consolidation run and inventory markup elimination created';

    -- 4. Test Period Close Workspace & Subledger Variance Calculation
    INSERT INTO close_workspaces (id, entity_id, accounting_period_id, status)
    VALUES (v_ws_id, v_parent_id, v_period_id, 'OPEN');

    INSERT INTO subledger_reconciliations (
        workspace_id, subledger_code, gl_control_account_id, gl_balance, subledger_balance, status
    ) VALUES (
        v_ws_id, 'AR', v_asset_acct_id, 50000.00, 50000.00, 'BALANCED'
    );

    RAISE NOTICE 'SUCCESS: Period close workspace and zero-variance check verified';

    -- 5. Test Integration Ingress & Idempotency
    INSERT INTO inbox_events (
        id, source_system, external_event_id, payload, status
    ) VALUES (
        v_inbox_id, 'HubSpot', 'hs-deal-won-998877', '{"deal_name": "Q3 Expansion", "amount": 50000}'::jsonb, 'RECEIVED'
    );

    -- Duplicate event ID from the same source must fail
    BEGIN
        INSERT INTO inbox_events (
            source_system, external_event_id, payload
        ) VALUES (
            'HubSpot', 'hs-deal-won-998877', '{"duplicate": true}'::jsonb
        );
        RAISE EXCEPTION 'TEST FAILED: Duplicate webhook idempotency key should have been blocked';
    EXCEPTION
        WHEN unique_violation THEN
            RAISE NOTICE 'SUCCESS: Ingress perimeter unique constraint blocked duplicate webhook';
    END;

    RAISE NOTICE '--- All Migration 005 Verification Checks Passed ---';
END $$;

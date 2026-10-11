-- verify_schema_v2.sql

DO $$
DECLARE
    v_user_id uuid := gen_random_uuid();
    v_entity_id uuid := gen_random_uuid();
    v_ledger_id uuid := gen_random_uuid();
    v_period1_id uuid := gen_random_uuid();
    v_period2_id uuid := gen_random_uuid();
    v_account_cash_id uuid := gen_random_uuid();
    v_account_rev_id uuid := gen_random_uuid();
    v_dim_set_id uuid := gen_random_uuid();
    v_rule_id uuid := gen_random_uuid();
    v_be1_id uuid := gen_random_uuid();
    v_ae1_id uuid := gen_random_uuid();
    v_be2_id uuid := gen_random_uuid();
    v_ae2_id uuid := gen_random_uuid();
    v_be3_id uuid := gen_random_uuid();
    v_ae3_id uuid := gen_random_uuid();
    v_source1_id uuid := gen_random_uuid();
    v_source2_id uuid := gen_random_uuid();
    v_source3_id uuid := gen_random_uuid();
BEGIN
    -- 1. Setup seed data
    INSERT INTO users (id, email, display_name, is_active) 
    VALUES (v_user_id, 'admin@test.com', 'Admin User', true);

    INSERT INTO entities (id, code, legal_name, base_currency, country_code, is_active) 
    VALUES (v_entity_id, 'ENT001', 'Test Entity', 'AUD', 'AU', true);

    INSERT INTO tenant_settings (singleton, tenant_code, group_reporting_currency) 
    VALUES (true, 'TEST_TENANT', 'USD');

    INSERT INTO ledgers (id, code, name, ledger_type, accounting_framework, entity_id, ledger_currency, is_active) 
    VALUES (v_ledger_id, 'MAIN', 'Main Ledger', 'PRIMARY', 'IFRS', v_entity_id, 'AUD', true);

    INSERT INTO accounting_periods (id, entity_id, fiscal_year, period_number, period_name, period_type, start_date, end_date, status)
    VALUES 
    (v_period1_id, v_entity_id, 2023, 1, '2023-Jan', 'REGULAR', '2023-01-01', '2023-01-31', 'OPEN'),
    (v_period2_id, v_entity_id, 2023, 2, '2023-Feb', 'REGULAR', '2023-02-01', '2023-02-28', 'CLOSED');

    INSERT INTO accounts (id, code, name, account_type, is_postable, is_control_account, is_active)
    VALUES 
    (v_account_cash_id, '1000', 'Cash', 'ASSET', true, false, true),
    (v_account_rev_id, '4000', 'Revenue', 'REVENUE', true, false, true);

    INSERT INTO dimension_sets (id, set_hash) VALUES (v_dim_set_id, '\x00');

    INSERT INTO accounting_rules (id, code, description) VALUES (v_rule_id, 'Rule001', 'Default Rule');

    INSERT INTO accounting_rule_versions (rule_id, version, status, effective_from, definition, approved_by, approved_at)
    VALUES (v_rule_id, 1, 'ACTIVE', '2020-01-01', '{}'::jsonb, v_user_id, now());

    -- 2. Test valid entry (Should succeed)
    INSERT INTO business_events (id, entity_id, event_type, source_object_type, source_object_id, idempotency_key, payload, payload_sha256, occurred_at)
    VALUES (v_be1_id, v_entity_id, 'ManualJournal', 'JOURNAL', v_source1_id, 'key1', '{}'::jsonb, '\x01', '2023-01-15 10:00:00Z');

    INSERT INTO accounting_events (id, business_event_id, entity_id, ledger_id, accounting_period_id, economic_date, accounting_date, rule_id, rule_version)
    VALUES (v_ae1_id, v_be1_id, v_entity_id, v_ledger_id, v_period1_id, '2023-01-15', '2023-01-15', v_rule_id, 1);

    -- We must insert ledger entries that balance. We do it in one transaction/statement so deferrable trigger works.
    INSERT INTO ledger_entries (
        accounting_event_id, line_number, ledger_id, accounting_period_id, account_id,
        dimension_set_id, accounting_date, transaction_currency, transaction_amount, exchange_rate, base_amount,
        reporting_currency, reporting_rate, reporting_amount, description
    ) VALUES 
    (v_ae1_id, 1, v_ledger_id, v_period1_id, v_account_cash_id, v_dim_set_id, '2023-01-15', 'AUD', 100.0, 1.0, 100.0, 'USD', 0.7, 70.0, 'Sale DR'),
    (v_ae1_id, 2, v_ledger_id, v_period1_id, v_account_rev_id, v_dim_set_id, '2023-01-15', 'AUD', -100.0, 1.0, -100.0, 'USD', 0.7, -70.0, 'Sale CR');
    RAISE NOTICE 'Valid entry inserted successfully';

    -- 3. Test unbalanced entry (Should fail)
    -- In PL/pgSQL, any error aborts the current block unless handled in a sub-block (BEGIN...EXCEPTION...END)
    BEGIN
        INSERT INTO business_events (id, entity_id, event_type, source_object_type, source_object_id, idempotency_key, payload, payload_sha256, occurred_at)
        VALUES (v_be2_id, v_entity_id, 'ManualJournal', 'JOURNAL', v_source2_id, 'key2', '{}'::jsonb, '\x02', '2023-01-16 10:00:00Z');

        INSERT INTO accounting_events (id, business_event_id, entity_id, ledger_id, accounting_period_id, economic_date, accounting_date, rule_id, rule_version)
        VALUES (v_ae2_id, v_be2_id, v_entity_id, v_ledger_id, v_period1_id, '2023-01-16', '2023-01-16', v_rule_id, 1);

        INSERT INTO ledger_entries (
            accounting_event_id, line_number, ledger_id, accounting_period_id, account_id,
            dimension_set_id, accounting_date, transaction_currency, transaction_amount, exchange_rate, base_amount,
            reporting_currency, reporting_rate, reporting_amount, description
        ) VALUES 
        (v_ae2_id, 1, v_ledger_id, v_period1_id, v_account_cash_id, v_dim_set_id, '2023-01-16', 'AUD', 100.0, 1.0, 100.0, 'USD', 0.7, 70.0, 'Sale DR'),
        (v_ae2_id, 2, v_ledger_id, v_period1_id, v_account_rev_id, v_dim_set_id, '2023-01-16', 'AUD', -90.0, 1.0, -90.0, 'USD', 0.7, -63.0, 'Sale CR');
        
        -- Force deferrable constraints to be checked NOW so we can catch the error
        SET CONSTRAINTS ct_ledger_entries_balanced IMMEDIATE;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'Unbalanced entry rejected successfully: %', SQLERRM;
            -- Reset constraint back to deferred
            SET CONSTRAINTS ct_ledger_entries_balanced DEFERRED;
    END;

    -- 4. Test updating a posted ledger line (Should fail)
    BEGIN
        UPDATE ledger_entries SET transaction_amount = 200.0 WHERE accounting_event_id = v_ae1_id;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'Ledger entry update rejected successfully: %', SQLERRM;
    END;

    -- 5. Test posting to a closed period (Should fail)
    BEGIN
        INSERT INTO business_events (id, entity_id, event_type, source_object_type, source_object_id, idempotency_key, payload, payload_sha256, occurred_at)
        VALUES (v_be3_id, v_entity_id, 'ManualJournal', 'JOURNAL', v_source3_id, 'key3', '{}'::jsonb, '\x03', '2023-02-15 10:00:00Z');

        INSERT INTO accounting_events (id, business_event_id, entity_id, ledger_id, accounting_period_id, economic_date, accounting_date, rule_id, rule_version)
        VALUES (v_ae3_id, v_be3_id, v_entity_id, v_ledger_id, v_period2_id, '2023-02-15', '2023-02-15', v_rule_id, 1);

        INSERT INTO ledger_entries (
            accounting_event_id, line_number, ledger_id, accounting_period_id, account_id,
            dimension_set_id, accounting_date, transaction_currency, transaction_amount, exchange_rate, base_amount,
            reporting_currency, reporting_rate, reporting_amount, description
        ) VALUES 
        (v_ae3_id, 1, v_ledger_id, v_period2_id, v_account_cash_id, v_dim_set_id, '2023-02-15', 'AUD', 100.0, 1.0, 100.0, 'USD', 0.7, 70.0, 'Sale DR'),
        (v_ae3_id, 2, v_ledger_id, v_period2_id, v_account_rev_id, v_dim_set_id, '2023-02-15', 'AUD', -100.0, 1.0, -100.0, 'USD', 0.7, -70.0, 'Sale CR');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'Posting to closed period rejected successfully: %', SQLERRM;
    END;

END $$;

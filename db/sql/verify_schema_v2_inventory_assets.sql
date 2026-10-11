-- =============================================================================
-- FILE:    verify_schema_v2_inventory_assets.sql
-- SYSTEM:  HRT Systems (Radical TG) - Verification for Migration 004
-- PURPOSE: Tests that Migration 004 enforces operational integrity,
--          inventory cost layers, dual-book asset registers, AASB 16 leases,
--          projects/WIP, and payroll ingestion.
-- =============================================================================

DO $$
DECLARE
    v_user_id        uuid := gen_random_uuid();
    v_entity_id      uuid := gen_random_uuid();
    v_ledger_id      uuid := gen_random_uuid();
    v_period_id      uuid := gen_random_uuid();
    v_cust_id        uuid := gen_random_uuid();
    v_lessor_id      uuid := gen_random_uuid();
    v_uom_id         uuid := gen_random_uuid();
    v_item_id        uuid := gen_random_uuid();
    v_loc_id         uuid := gen_random_uuid();
    v_be_id          uuid := gen_random_uuid();
    v_mvt_id         uuid := gen_random_uuid();
    v_ppe_acct_id    uuid := gen_random_uuid();
    v_accum_acct_id  uuid := gen_random_uuid();
    v_exp_acct_id    uuid := gen_random_uuid();
    v_rou_acct_id    uuid := gen_random_uuid();
    v_liab_acct_id   uuid := gen_random_uuid();
    v_int_acct_id    uuid := gen_random_uuid();
    v_asset_id       uuid := gen_random_uuid();
    v_book_id        uuid := gen_random_uuid();
    v_lease_id       uuid := gen_random_uuid();
    v_project_id     uuid := gen_random_uuid();
    v_task_id        uuid := gen_random_uuid();
    v_ts_id          uuid := gen_random_uuid();
    v_payroll_id     uuid := gen_random_uuid();
    v_dim_set_id     uuid := gen_random_uuid();
BEGIN
    RAISE NOTICE '--- Starting Migration 004 Verification ---';

    -- 1. Setup seed users, entity, ledger, period, customer
    INSERT INTO users (id, email, display_name, is_active)
    VALUES (v_user_id, 'operations@company.com', 'Operations Lead', true);

    INSERT INTO entities (id, code, legal_name, base_currency, country_code, is_active)
    VALUES (v_entity_id, 'AU03', 'Industrial Manufacturing Pty Ltd', 'AUD', 'AU', true);

    INSERT INTO ledgers (id, code, name, ledger_type, accounting_framework, entity_id, ledger_currency, is_active)
    VALUES (v_ledger_id, 'MAIN_AU03', 'Primary Ledger', 'PRIMARY', 'AASB', v_entity_id, 'AUD', true);

    INSERT INTO accounting_periods (id, entity_id, fiscal_year, period_number, period_name, period_type, start_date, end_date, status)
    VALUES (v_period_id, v_entity_id, 2026, 2, '2026-Q2', 'REGULAR', '2026-10-01', '2026-12-31', 'OPEN');

    INSERT INTO parties (id, party_type, code, name, default_currency, is_active)
    VALUES (v_cust_id, 'CUSTOMER', 'CLT-100', 'Infrastructure Client Corp', 'AUD', true),
           (v_lessor_id, 'SUPPLIER', 'LSR-200', 'Commercial Real Estate Trust', 'AUD', true);

    INSERT INTO units_of_measure (id, code, name, symbol, is_active)
    VALUES (v_uom_id, 'KG', 'Kilogram', 'kg', true);

    INSERT INTO items (id, code, name, item_type, base_uom_id, is_active)
    VALUES (v_item_id, 'STEEL-PLATE-01', 'Structural Steel Plate', 'STOCK', v_uom_id, true);

    INSERT INTO business_events (
        id, entity_id, event_type, source_object_type, source_object_id,
        idempotency_key, payload, payload_sha256, occurred_at
    ) VALUES (
        v_be_id, v_entity_id, 'InventoryReceived', 'GoodsReceipt', gen_random_uuid(),
        'inv-be-key-100', '{}'::jsonb, '\x09', now()
    );

    -- 2. Test Inventory Subledger & Cost Layers (AASB 102)
    INSERT INTO inventory_locations (id, entity_id, code, name, location_type, is_active)
    VALUES (v_loc_id, v_entity_id, 'WH-SYD', 'Sydney Distribution Centre', 'WAREHOUSE', true);

    INSERT INTO inventory_movements (
        id, entity_id, business_event_id, item_id, location_id, movement_type,
        quantity, uom_id, unit_cost, total_cost, occurred_at
    ) VALUES (
        v_mvt_id, v_entity_id, v_be_id, v_item_id, v_loc_id, 'RECEIPT',
        500.00, v_uom_id, 12.50, 6250.00, now()
    );

    -- Movement log must be immutable
    BEGIN
        UPDATE inventory_movements SET quantity = 600.00 WHERE id = v_mvt_id;
        RAISE EXCEPTION 'TEST FAILED: inventory_movements update should have failed';
    EXCEPTION
        WHEN restrict_violation THEN
            RAISE NOTICE 'SUCCESS: inventory_movements immutability trigger blocked UPDATE';
    END;

    INSERT INTO inventory_cost_layers (
        entity_id, item_id, location_id, layer_date, original_quantity, remaining_quantity, unit_cost
    ) VALUES (
        v_entity_id, v_item_id, v_loc_id, '2026-10-01', 500.00, 500.00, 12.50
    );

    RAISE NOTICE 'SUCCESS: Inventory movement and cost layer registered';

    -- 3. Test Fixed Assets & Dual-Book Depreciation (AASB 116)
    INSERT INTO accounts (id, code, name, account_type, is_postable, is_active)
    VALUES (v_ppe_acct_id, '1510', 'Plant & Equipment', 'ASSET', true, true),
           (v_accum_acct_id, '1519', 'Accumulated Depreciation - Plant', 'ASSET', true, true),
           (v_exp_acct_id, '6300', 'Depreciation Expense', 'EXPENSE', true, true);

    INSERT INTO fixed_assets (
        id, entity_id, asset_number, name, serial_number, acquisition_date, in_service_date,
        original_cost, currency_code, status
    ) VALUES (
        v_asset_id, v_entity_id, 'FA-CNC-001', '5-Axis CNC Milling Machine', 'SN-998822',
        '2026-10-01', '2026-10-05', 120000.00, 'AUD', 'IN_SERVICE'
    );

    -- Setup AASB Book
    INSERT INTO asset_books (
        id, asset_id, book_type, ledger_id, asset_account_id, accum_deprec_account_id,
        deprec_expense_account_id, depreciation_method, useful_life_months, cost_basis
    ) VALUES (
        v_book_id, v_asset_id, 'AASB_BOOK', v_ledger_id, v_ppe_acct_id, v_accum_acct_id,
        v_exp_acct_id, 'STRAIGHT_LINE', 60, 120000.00
    );

    -- Post Depreciation Transaction
    INSERT INTO asset_transactions (
        asset_id, book_id, business_event_id, transaction_type, transaction_date, amount
    ) VALUES (
        v_asset_id, v_book_id, v_be_id, 'DEPRECIATION', '2026-10-31', 2000.00
    );

    RAISE NOTICE 'SUCCESS: Fixed asset and parallel depreciation book created';

    -- 4. Test AASB 16 Lease Engine
    INSERT INTO accounts (id, code, name, account_type, is_postable, is_active)
    VALUES (v_rou_acct_id, '1600', 'Right-of-Use Asset (Property)', 'ASSET', true, true),
           (v_liab_acct_id, '2600', 'Lease Liability (AASB 16)', 'LIABILITY', true, true),
           (v_int_acct_id, '6800', 'Lease Interest Expense', 'EXPENSE', true, true);

    INSERT INTO lease_contracts (
        id, entity_id, lessor_party_id, contract_number, commencement_date, termination_date,
        lease_term_months, discount_rate_pct, initial_rou_asset_val, initial_liability_val,
        rou_asset_account_id, lease_liab_account_id, interest_account_id
    ) VALUES (
        v_lease_id, v_entity_id, v_lessor_id, 'LEASE-HQ-2026', '2026-10-01', '2029-09-30',
        36, 6.5000, 300000.00, 300000.00, v_rou_acct_id, v_liab_acct_id, v_int_acct_id
    );

    INSERT INTO lease_schedules (
        lease_id, period_number, payment_date, payment_amount, principal_amount,
        interest_amount, rou_depreciation, closing_liability
    ) VALUES (
        v_lease_id, 1, '2026-10-31', 9500.00, 7875.00, 1625.00, 8333.33, 292125.00
    );

    RAISE NOTICE 'SUCCESS: AASB 16 lease contract and schedule line created';

    -- 5. Test Projects, Timesheets & Contract WIP (AASB 15)
    INSERT INTO projects (
        id, entity_id, customer_party_id, code, name, billing_type, contract_value, currency_code, start_date
    ) VALUES (
        v_project_id, v_entity_id, v_cust_id, 'PRJ-SYD-BRIDGE', 'Harbour Bridge Structural Retrofit',
        'TIME_AND_MATERIALS', 500000.00, 'AUD', '2026-10-01'
    );

    INSERT INTO project_tasks (id, project_id, code, name, is_billable)
    VALUES (v_task_id, v_project_id, 'TASK-DESIGN', 'Engineering Design & FEA', true);

    INSERT INTO timesheets (id, entity_id, user_id, week_start, status)
    VALUES (v_ts_id, v_entity_id, v_user_id, '2026-10-05', 'APPROVED');

    INSERT INTO timesheet_lines (
        timesheet_id, project_id, task_id, work_date, hours_worked, cost_rate, bill_rate, description
    ) VALUES (
        v_ts_id, v_project_id, v_task_id, '2026-10-06', 8.00, 85.00, 220.00, 'Structural stress simulation'
    );

    -- Unbilled Contract Asset WIP Entry
    INSERT INTO project_wip_entries (
        entity_id, project_id, business_event_id, source_type, source_id, cost_amount, billable_amount, is_billed
    ) VALUES (
        v_entity_id, v_project_id, v_be_id, 'TIMESHEET', v_ts_id, 680.00, 1760.00, false
    );

    RAISE NOTICE 'SUCCESS: Project and unbilled contract WIP entry created';

    -- 6. Test External Payroll Ingestion & Superannuation Guarantee
    INSERT INTO dimension_sets (id, set_hash) VALUES (v_dim_set_id, '\x04');

    INSERT INTO payroll_runs (
        id, entity_id, external_system, external_run_id, pay_period_start, pay_period_end, payment_date,
        gross_wages, net_wages, payg_withholding, superannuation_sg
    ) VALUES (
        v_payroll_id, v_entity_id, 'EmploymentHero', 'RUN-EH-2026-10A', '2026-10-01', '2026-10-14', '2026-10-15',
        100000.00, 68000.00, 32000.00, 11500.00 -- 11.5% SG Super
    );

    INSERT INTO payroll_cost_allocations (
        payroll_run_id, dimension_set_id, allocated_wages, allocated_super
    ) VALUES (
        v_payroll_id, v_dim_set_id, 100000.00, 11500.00
    );

    RAISE NOTICE 'SUCCESS: External payroll batch ingested with Super Guarantee SG';

    RAISE NOTICE '--- All Migration 004 Verification Checks Passed ---';
END $$;

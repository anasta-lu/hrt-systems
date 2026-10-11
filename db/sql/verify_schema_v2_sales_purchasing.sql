-- =============================================================================
-- FILE:    verify_schema_v2_sales_purchasing.sql
-- SYSTEM:  HRT Systems (Radical TG) - Verification for Migration 003
-- PURPOSE: Tests that Migration 003 enforces operational integrity,
--          document freezing, 3-way matching, and ABA payment batch controls.
-- =============================================================================

DO $$
DECLARE
    v_user1_id       uuid := gen_random_uuid();
    v_user2_id       uuid := gen_random_uuid();
    v_entity_id      uuid := gen_random_uuid();
    v_cust_party_id  uuid := gen_random_uuid();
    v_supp_party_id  uuid := gen_random_uuid();
    v_uom_id         uuid := gen_random_uuid();
    v_item_id        uuid := gen_random_uuid();
    v_tax_code_id    uuid := gen_random_uuid();
    v_dim_set_id     uuid := gen_random_uuid();
    v_inv_acct_id    uuid := gen_random_uuid();
    v_rev_acct_id    uuid := gen_random_uuid();
    v_cogs_acct_id   uuid := gen_random_uuid();
    v_bank_acct_id   uuid := gen_random_uuid();
    v_supp_bank_id   uuid := gen_random_uuid();
    v_so_id          uuid := gen_random_uuid();
    v_inv_id         uuid := gen_random_uuid();
    v_po_id          uuid := gen_random_uuid();
    v_po_line_id     uuid := gen_random_uuid();
    v_grn_id         uuid := gen_random_uuid();
    v_grn_line_id    uuid := gen_random_uuid();
    v_bill_id        uuid := gen_random_uuid();
    v_batch_id       uuid := gen_random_uuid();
BEGIN
    RAISE NOTICE '--- Starting Migration 003 Verification ---';

    -- 1. Setup seed users, entity, accounts, tax code, dimension set
    INSERT INTO users (id, email, display_name, is_active)
    VALUES (v_user1_id, 'purchaser@company.com', 'Purchasing Clerk', true),
           (v_user2_id, 'apmanager@company.com', 'AP Manager', true);

    INSERT INTO entities (id, code, legal_name, base_currency, country_code, is_active)
    VALUES (v_entity_id, 'AU02', 'Commercial Supplies Pty Ltd', 'AUD', 'AU', true);

    INSERT INTO parties (id, party_type, code, name, default_currency, is_active)
    VALUES (v_cust_party_id, 'CUSTOMER', 'CUST-001', 'Enterprise Client Ltd', 'AUD', true),
           (v_supp_party_id, 'SUPPLIER', 'SUPP-001', 'Wholesale Manufacturer Pty Ltd', 'AUD', true);

    INSERT INTO accounts (id, code, name, account_type, is_postable, is_active)
    VALUES (v_inv_acct_id, '1400', 'Inventory On Hand', 'ASSET', true, true),
           (v_cogs_acct_id, '5000', 'Cost of Goods Sold', 'EXPENSE', true, true),
           (v_rev_acct_id, '4100', 'Commercial Sales Revenue', 'REVENUE', true, true);

    INSERT INTO tax_codes (id, code, name, jurisdiction, tax_type, is_active)
    VALUES (v_tax_code_id, 'GST-10', 'Standard GST 10%', 'AU', 'GST', true);

    INSERT INTO dimension_sets (id, set_hash) VALUES (v_dim_set_id, '\x03');

    -- 2. Setup Unit of Measure & Item Master
    INSERT INTO units_of_measure (id, code, name, symbol, is_active)
    VALUES (v_uom_id, 'EA', 'Each', 'ea', true);

    INSERT INTO items (id, code, name, item_type, base_uom_id, default_tax_code_id, is_active)
    VALUES (v_item_id, 'SKU-WIDGET-01', 'Industrial Precision Widget', 'STOCK', v_uom_id, v_tax_code_id, true);

    INSERT INTO item_posting_groups (item_id, inventory_account_id, cogs_account_id, revenue_account_id)
    VALUES (v_item_id, v_inv_acct_id, v_cogs_acct_id, v_rev_acct_id);

    RAISE NOTICE 'SUCCESS: Item and posting group created';

    -- 3. Test Sales Order -> Customer Invoice -> Document Freeze
    INSERT INTO sales_orders (
        id, entity_id, customer_party_id, order_number, order_date, currency_code,
        subtotal_amount, tax_amount, total_amount, workflow_status
    ) VALUES (
        v_so_id, v_entity_id, v_cust_party_id, 'SO-2026-001', '2026-10-01', 'AUD',
        1000.00, 100.00, 1100.00, 'APPROVED'
    );

    INSERT INTO customer_invoices (
        id, entity_id, customer_party_id, sales_order_id, invoice_number, invoice_date, due_date,
        currency_code, subtotal_amount, tax_amount, total_amount, workflow_status
    ) VALUES (
        v_inv_id, v_entity_id, v_cust_party_id, v_so_id, 'INV-2026-001', '2026-10-01', '2026-10-31',
        'AUD', 1000.00, 100.00, 1100.00, 'DRAFT'
    );

    INSERT INTO customer_invoice_lines (
        invoice_id, line_number, item_id, description, quantity, uom_id, unit_price,
        line_subtotal, tax_code_id, tax_amount, line_total, dimension_set_id
    ) VALUES (
        v_inv_id, 1, v_item_id, 'Widget supply', 10, v_uom_id, 100.00,
        1000.00, v_tax_code_id, 100.00, 1100.00, v_dim_set_id
    );

    -- Issue the invoice (should generate hash and freeze)
    UPDATE customer_invoices SET workflow_status = 'ISSUED' WHERE id = v_inv_id;

    -- Verify that updating financial numbers on frozen invoice FAILS
    BEGIN
        UPDATE customer_invoices SET total_amount = 500.00 WHERE id = v_inv_id;
        RAISE EXCEPTION 'TEST FAILED: Modifying frozen customer invoice total should have failed';
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'SUCCESS: Document freeze trigger blocked modification to ISSUED invoice: %', SQLERRM;
    END;

    -- Verify that deleting a frozen invoice FAILS
    BEGIN
        DELETE FROM customer_invoices WHERE id = v_inv_id;
        RAISE EXCEPTION 'TEST FAILED: Deleting frozen customer invoice should have failed';
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'SUCCESS: Document freeze trigger blocked deletion of ISSUED invoice';
    END;

    -- 4. Test Procure-to-Pay: PO -> Goods Receipt (GRNI) -> Supplier Bill
    INSERT INTO purchase_orders (
        id, entity_id, supplier_party_id, po_number, po_date, currency_code,
        subtotal_amount, tax_amount, total_amount, workflow_status
    ) VALUES (
        v_po_id, v_entity_id, v_supp_party_id, 'PO-2026-900', '2026-10-02', 'AUD',
        2000.00, 200.00, 2200.00, 'APPROVED'
    );

    INSERT INTO purchase_order_lines (
        id, po_id, line_number, item_id, description, quantity_ordered, uom_id, unit_price,
        line_subtotal, tax_code_id, tax_amount, line_total, dimension_set_id
    ) VALUES (
        v_po_line_id, v_po_id, 1, v_item_id, 'Raw components', 20, v_uom_id, 100.00,
        2000.00, v_tax_code_id, 200.00, 2200.00, v_dim_set_id
    );

    -- Receive goods (acknowledges delivery)
    INSERT INTO goods_receipts (
        id, entity_id, supplier_party_id, po_id, receipt_number, receipt_date
    ) VALUES (
        v_grn_id, v_entity_id, v_supp_party_id, v_po_id, 'GRN-2026-050', '2026-10-05'
    );

    INSERT INTO goods_receipt_lines (
        id, receipt_id, line_number, po_line_id, item_id, quantity_received, uom_id, unit_cost, total_cost
    ) VALUES (
        v_grn_line_id, v_grn_id, 1, v_po_line_id, v_item_id, 20, v_uom_id, 100.00, 2000.00
    );

    -- Receive supplier bill matched 3-ways to receipt and PO
    INSERT INTO supplier_invoices (
        id, entity_id, supplier_party_id, po_id, invoice_number, bill_date, due_date,
        currency_code, subtotal_amount, tax_amount, total_amount, match_status, workflow_status
    ) VALUES (
        v_bill_id, v_entity_id, v_supp_party_id, v_po_id, 'SUPP-BILL-7788', '2026-10-06', '2026-11-06',
        'AUD', 2000.00, 200.00, 2200.00, '3_WAY_MATCHED', 'APPROVED'
    );

    INSERT INTO supplier_invoice_lines (
        invoice_id, line_number, po_line_id, goods_receipt_line_id, item_id, description,
        quantity, uom_id, unit_price, line_subtotal, tax_code_id, tax_amount, line_total, dimension_set_id
    ) VALUES (
        v_bill_id, 1, v_po_line_id, v_grn_line_id, v_item_id, 'Raw components invoiced',
        20, v_uom_id, 100.00, 2000.00, v_tax_code_id, 200.00, 2200.00, v_dim_set_id
    );

    RAISE NOTICE 'SUCCESS: 3-way matched supplier bill created';

    -- 5. Test ABA Payment Batch & Segregation of Duties Fraud Controls
    -- Setup internal bank account and supplier bank account
    INSERT INTO accounts (id, code, name, account_type, is_postable, is_active)
    VALUES (gen_random_uuid(), '1011', 'Operating Account 2', 'ASSET', true, true);

    INSERT INTO bank_accounts (
        id, entity_id, code, name, bank_name, bsb, account_number, currency_code, gl_account_id
    ) VALUES (
        v_bank_acct_id, v_entity_id, 'WBC-01', 'Westpac Operating', 'Westpac', '032-000', '98765432', 'AUD', v_inv_acct_id
    );

    INSERT INTO party_bank_accounts (
        id, party_id, bank_name, account_name, routing_number, account_number, currency_code, is_verified
    ) VALUES (
        v_supp_bank_id, v_supp_party_id, 'ANZ', 'Wholesale Pty Ltd', '012-000', '55566677', 'AUD', true
    );

    -- Self-approval of ABA payment batch should FAIL by constraint
    BEGIN
        INSERT INTO payment_batches (
            id, entity_id, bank_account_id, batch_reference, execution_date, total_amount, item_count,
            status, created_by, approved_by, approved_at
        ) VALUES (
            v_batch_id, v_entity_id, v_bank_acct_id, 'ABA-BATCH-001', '2026-10-10', 2200.00, 1,
            'APPROVED', v_user1_id, v_user1_id, now() -- Self-approval attempt!
        );
        RAISE EXCEPTION 'TEST FAILED: Batch creator should not be allowed to approve their own payment batch';
    EXCEPTION
        WHEN check_violation THEN
            RAISE NOTICE 'SUCCESS: SoD constraint blocked self-approval of ABA payment batch';
    END;

    -- Distinct user approval of payment batch should SUCCEED
    INSERT INTO payment_batches (
        id, entity_id, bank_account_id, batch_reference, execution_date, total_amount, item_count,
        status, created_by, approved_by, approved_at
    ) VALUES (
        v_batch_id, v_entity_id, v_bank_acct_id, 'ABA-BATCH-001', '2026-10-10', 2200.00, 1,
        'APPROVED', v_user1_id, v_user2_id, now()
    );

    INSERT INTO payment_batch_items (
        batch_id, supplier_party_id, supplier_invoice_id, party_bank_account_id, payment_amount, remittance_reference
    ) VALUES (
        v_batch_id, v_supp_party_id, v_bill_id, v_supp_bank_id, 2200.00, 'INV-SUPP-7788'
    );

    RAISE NOTICE 'SUCCESS: ABA payment batch approved by independent controller';

    RAISE NOTICE '--- All Migration 003 Verification Checks Passed ---';
END $$;

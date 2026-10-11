# SDLC 23: Complete ERP Data Architecture & Master Database Design

## 1. Executive Vision & Foundational Invariants

This document establishes the exhaustive, complete **Data Architecture** for **HRT Systems (Project AX)** across all 20 business domains. It defines every database table, entity relationship, immutability constraint, and foreign key contract required to build the entire ERP to specification.

### 1.1. The 9 Structural Table Archetypes
Every table in HRT Systems strictly belongs to one of nine architectural archetypes. This eliminates ad-hoc table design and enforces uniform auditability, concurrency, and lifecycle rules across the platform:

| # | Table Archetype | Mutability Rules | Standard Required Columns | Examples |
|---|---|---|---|---|
| **1** | **Reference & Configuration** | Effective-dated, no hard deletes | `code`, `name`, `is_active`, `valid_from`, `valid_to`, `created_at` | `currencies`, `tax_codes`, `close_gate_definitions`, `dimensions` |
| **2** | **Master Data** | Mutable with versioning, soft-deactivate | `id`, `code`, `name`, `is_active`, `lock_version`, `created_at`, `updated_at` | `parties`, `items`, `accounts`, `bank_accounts`, `fixed_assets`, `projects` |
| **3** | **Operational Documents** | Mutable while DRAFT; **Frozen & Hashed once APPROVED/ISSUED** | `id`, `document_number`, `document_date`, `workflow_status`, `accounting_status`, `settlement_status`, `lock_version`, `document_hash` | `sales_orders`, `customer_invoices`, `purchase_orders`, `supplier_invoices`, `timesheets` |
| **4** | **Business & Control Events** | **100% Immutable (Insert-Only)**; Triggers reject UPDATE/DELETE/TRUNCATE | `id`, `entity_id`, `event_type`, `source_object_type`, `source_object_id`, `occurred_at`, `recorded_at`, `actor_id`, `idempotency_key`, `payload`, `payload_sha256` | `business_events`, `control_events` |
| **5** | **General Ledger** | **100% Immutable (Insert-Only)**; Double-entry balanced; Reversals only | `id`, `accounting_event_id`, `ledger_id`, `accounting_period_id`, `accounting_date`, `account_id`, `dimension_set_id`, `transaction_amount`, `base_amount`, `reporting_amount` | `accounting_events`, `ledger_entries`, `period_balances` |
| **6** | **Subledger Movements** | **100% Immutable (Insert-Only)**; Balances computed via sum of movements | `id`, `entity_id`, `business_event_id`, `party_id`, `amount`, `allocated_date`, `movement_type` | `open_items`, `open_item_allocations`, `inventory_movements`, `inventory_cost_layers`, `tax_lines` |
| **7** | **Workflow & Approvals** | **100% Immutable (Insert-Only)**; Tied to document version & hash | `id`, `document_type`, `document_id`, `document_lock_version`, `document_hash`, `approver_id`, `action`, `decision_at`, `notes` | `approval_requests`, `approval_decisions`, `bank_account_change_approvals` |
| **8** | **Integration Perimeter** | **Append-Only** with replay counters | `id`, `business_event_id`, `topic`, `payload`, `status`, `attempts`, `created_at`, `published_at` | `inbox_events`, `outbox_events`, `external_id_mappings`, `dead_letter_queue` |
| **9** | **Evidence & Provenance** | **100% Immutable (Insert-Only)**; Cryptographic hashing | `id`, `storage_uri`, `sha256_hex`, `mime_type`, `size_bytes`, `uploaded_by`, `uploaded_at` | `evidence_files`, `audit_log`, `auditor_request_items` |

---

## 2. Complete Inventory of All 20 ERP Database Domains

Below is the definitive catalog of all 20 bounded context domains, their tables, relationships, and business rules:

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                 THE COMPLETE AX DATA ARCHITECTURE                                │
├───────────────────────────────┬─────────────────────────────────┬───────────────────────────────┤
│ FOUNDATIONAL DOMAINS          │ OPERATIONAL DOCUMENT DOMAINS    │ SUBLEDGER & KERNEL DOMAINS    │
│ 1. Organisation & Entities    │ 6. Sales & Billing (AR)         │ 10. Inventory Subledger       │
│ 2. Security & RBAC / SoD      │ 7. Procurement & Payables (AP)  │ 11. Fixed Assets & Leases     │
│ 3. Universal Party Master     │ 8. Banking & Reconciliation     │ 12. Projects, Time & WIP      │
│ 4. Chart of Accounts & Dims   │ 9. Tax Engine & BAS Reporting   │ 13. Revenue Recognition       │
│ 5. Items, UOM & Price Lists   │ 14. Payroll & HRIS Clearing     │ 15. Core Accounting Kernel    │
│                               │                                 │ 16. Intercompany & Group      │
│                               │                                 │ 17. Period Close Workspace    │
│                               │                                 │ 18. Universal Workflow        │
│                               │                                 │ 19. Evidence & Audit Portal   │
│                               │                                 │ 20. Integration Perimeter     │
└───────────────────────────────┴─────────────────────────────────┴───────────────────────────────┘
```

---

### Domain 1: Organisation, Multi-Entity & Multi-Book
Provides multi-tenant physical isolation (Schema-per-Tenant) and multi-entity group consolidation.

* **`entities`**: Legal companies within the tenant.
  - Columns: `id (UUID)`, `code`, `legal_name`, `base_currency (FK)`, `country_code`, `parent_entity_id (FK)`, `entity_mode ('NATIVE','EXTERNAL_INTEGRATED','CONSOLIDATION_ONLY')`, `is_active`.
* **`org_units`**: Operational divisions, branches, regions, or cost centers within an entity.
  - Columns: `id (UUID)`, `entity_id (FK)`, `code`, `name`, `unit_type ('BRANCH','DEPARTMENT','DIVISION')`, `parent_unit_id (FK)`.
* **`ledgers`**: Parallel books per entity (Multi-Book Accounting).
  - Columns: `id (UUID)`, `entity_id (FK)`, `code`, `name`, `ledger_type ('PRIMARY','TAX','GROUP','MANAGEMENT')`, `accounting_framework ('AASB','IFRS','TAX_AU','US_GAAP')`, `ledger_currency (FK)`.
  - Invariant: Exactly one `PRIMARY` ledger per entity.
* **`accounting_calendars`**: Calendar schemes (Standard 12-Month, 4-4-5, 4-5-4, 13-Period).
* **`accounting_periods`**: Discrete financial periods.
  - Columns: `id (UUID)`, `entity_id (FK)`, `fiscal_year`, `period_number (1-16)`, `period_name`, `period_type ('REGULAR','ADJUSTMENT')`, `start_date`, `end_date`, `status ('FUTURE','OPEN','PENDING_CLOSE','CLOSED','REOPENED')`.
  - Invariant: `EXCLUDE USING gist` prevents overlapping regular periods for the same entity.
* **`subledger_period_statuses`**: Independent close gates per subledger.
  - Columns: `period_id (FK)`, `subledger_code ('AP','AR','BANK','PAYROLL','INVENTORY','ASSETS','REVENUE','TAX')`, `status ('OPEN','SOFT_LOCKED','FINAL_CLOSED')`.
* **`consolidation_groups` & `consolidation_group_members`**:
  - Columns: `group_id`, `member_entity_id`, `ownership_percentage`, `consolidation_method ('FULL','EQUITY')`, `valid_from`, `valid_to`.

---

### Domain 2: Security, RBAC & Segregation of Duties (SoD)
Enforces enterprise governance, dynamic data scoping, and mathematical fraud prevention.

* **`users`**: Actors within the tenant.
* **`roles`**: Standardized roles (`CFO`, `FINANCIAL_CONTROLLER`, `AP_CLERK`, `AR_CLERK`, `EXTERNAL_AUDITOR`).
* **`permissions`**: Granular resource actions (`customer_invoice:approve`, `bank_account:modify`, `period:reopen`).
* **`role_permissions`**: Mapping of roles to permissions.
* **`user_role_assignments`**: Assigns users to roles with optional entity and dimensional scopes.
* **`data_scopes`**:
  - Restricts user visibility: `user_id`, `scope_type ('ENTITY','DEPARTMENT','PROJECT')`, `scope_id`.
* **`sod_conflict_matrix`**: Defines mutually exclusive roles and actions.
  - Example: `Role A (Supplier Master Data Manager)` CONFLICTS WITH `Role B (Payment Batch Releaser)`.
* **`sod_override_logs`**: Immutable audit log of authorized emergency exceptions with CFO justification.

---

### Domain 3: Universal Party & Master Data
Eliminates fragmented customer/supplier tables. A single legal party can participate across multiple roles.

* **`parties`**: Core legal entity or individual.
  - Columns: `id (UUID)`, `party_type ('ORGANISATION','PERSON')`, `code`, `name`, `default_currency (FK)`, `is_active`.
* **`party_roles`**: Active roles assigned to the party.
  - Columns: `id (UUID)`, `party_id (FK)`, `role_type ('CUSTOMER','SUPPLIER','EMPLOYEE','CONTRACTOR','INTERCOMPANY')`, `is_active`.
* **`party_profiles`**: Commercial terms per role.
  - Columns: `party_id (FK)`, `role_type`, `payment_terms_days`, `credit_limit`, `currency_code`, `default_gl_account_id (FK)`, `default_tax_code_id (FK)`.
* **`party_addresses` & `party_contacts`**: Multiple effective-dated addresses (Billing, Shipping, Registered).
* **`party_bank_accounts`**: Bank details for accounts payable disbursements.
  - Columns: `party_id (FK)`, `bank_name`, `account_name`, `routing_number (BSB)`, `account_number`, `is_verified`, `is_primary`.
* **`bank_account_change_requests` & `bank_account_change_approvals`**:
  - Anti-Fraud Invariant: Any change to a supplier bank account requires dual-authorization (`approved_by != requested_by`).
* **`party_tax_registrations`**: ABN, NZBN, VAT registrations with effective-date exclusion constraints.
* **`party_merge_history`**: Audit log of consolidated duplicate master records.

---

### Domain 4: Chart of Accounts & Dynamic Dimensions
The financial classification backbone: thin natural accounts paired with hash-based dimensional sets.

* **`accounts`**: Thin Natural Accounts.
  - Columns: `id (UUID)`, `code`, `name`, `account_type ('ASSET','LIABILITY','EQUITY','REVENUE','EXPENSE')`, `normal_balance (GENERATED 'DR'/'CR')`, `parent_account_id (FK)`, `is_postable`, `is_control_account`, `is_active`.
* **`dimensions`**: Configurable reporting axes (`Department`, `Region`, `Project`, `Cost Center`, `Machine`).
* **`dimension_values`**: Allowed values per dimension with hierarchical rollups and valid-from/to dates.
* **`dimension_sets`**: Hash-based combinations of dimensions (`set_hash = SHA256(sorted dimension_value_ids)`).
* **`dimension_set_items`**: Junction table mapping `dimension_set_id` to individual `(dimension_id, dimension_value_id)`.
* **`account_dimension_rules`**: Enforces required dimensions per GL account (e.g., Travel Expense requires Department).
* **`account_mappings`**: Maps subsidiary local accounts to Group Master Accounts or Statutory Tax Charts.

---

### Domain 5: Items, Units of Measure & Price Lists
The product, inventory item, and service catalogue.

* **`units_of_measure`**: Base and derived units (`EA`, `HR`, `KG`, `M`, `BOX`).
* **`uom_conversions`**: Conversion multipliers (`1 BOX = 10 EA`).
* **`item_categories`**: Product hierarchy and reporting taxonomy.
* **`items`**: Item master records.
  - Columns: `id (UUID)`, `code`, `name`, `item_type ('STOCK','NON_STOCK','SERVICE','FIXED_ASSET')`, `base_uom_id (FK)`, `category_id (FK)`, `is_active`.
* **`item_posting_groups`**: GL account routing.
  - Columns: `item_id (FK)`, `inventory_account_id (FK)`, `cogs_account_id (FK)`, `revenue_account_id (FK)`, `expense_account_id (FK)`, `purchase_variance_account_id (FK)`.
* **`price_lists` & `price_list_items`**: Tiered price matrices by currency, volume break, and effective date.

---

### Domain 6: Sales & Accounts Receivable (AR)
End-to-end Quote-to-Cash workflow adhering to AASB 15.

* **`sales_quotes` & `sales_quote_lines`**: Pre-sale pricing commitments.
* **`sales_orders` & `sales_order_lines`**: Confirmed customer contracts; generates inventory reservations.
* **`customer_invoices`**: Billing documents issued to customers.
  - Columns: `id (UUID)`, `entity_id (FK)`, `customer_party_id (FK)`, `invoice_number`, `invoice_date`, `due_date`, `currency_code`, `exchange_rate`, `subtotal`, `tax_total`, `total_amount`, `workflow_status`, `accounting_status`, `settlement_status`, `lock_version`, `document_hash`.
* **`customer_invoice_lines`**:
  - Columns: `invoice_id (FK)`, `line_number`, `item_id (FK)`, `description`, `quantity`, `uom_id (FK)`, `unit_price`, `line_subtotal`, `tax_code_id (FK)`, `tax_amount`, `line_total`, `dimension_set_id (FK)`.
* **`credit_notes` & `credit_note_lines`**: Formal negative invoices for returns, billing errors, or discounts.
* **`customer_receipts`**: Payments received from customers.
  - Columns: `id (UUID)`, `entity_id (FK)`, `customer_party_id (FK)`, `bank_account_id (FK)`, `receipt_date`, `currency_code`, `amount_received`, `bank_clearing_status`, `unapplied_amount`.
* **`open_items`**: Subledger tracking of outstanding invoices and credit notes.
  - Columns: `id (UUID)`, `entity_id (FK)`, `party_id (FK)`, `item_type ('AR','AP')`, `document_number`, `currency_code`, `original_amount (SIGNED NUMERIC != 0)`, `document_date`, `due_date`.
* **`open_item_allocations`**: Many-to-many application of receipts and credit notes to open items.
* **`customer_refunds`**: Formal cash refunds back to customers.

---

### Domain 7: Procurement & Accounts Payable (AP)
Procure-to-Pay workflow with automated 3-way matching and GRNI accruals.

* **`purchase_requisitions` & `purchase_requisition_lines`**: Internal purchase requests.
* **`purchase_orders`**: Formal contracts with suppliers.
  - Columns: `id (UUID)`, `entity_id (FK)`, `supplier_party_id (FK)`, `po_number`, `po_date`, `currency_code`, `total_amount`, `workflow_status ('DRAFT','APPROVED','PARTIALLY_RECEIVED','CLOSED')`.
* **`purchase_order_lines`**: Line items with encumbered commitments.
* **`goods_receipts`**: Physical or service delivery acknowledgement.
  - Generates Business Event: `GoodsReceived` $\to$ Posts: **Dr Inventory / Expense, Cr GRNI Clearing Account**.
* **`goods_receipt_lines`**: Received quantities against PO lines.
* **`supplier_invoices` (Bills)**: Bills received from suppliers.
  - Columns: `id (UUID)`, `entity_id (FK)`, `supplier_party_id (FK)`, `invoice_number`, `bill_date`, `due_date`, `currency_code`, `subtotal`, `tax_amount`, `total_amount`, `match_status ('UNMATCHED','2_WAY_MATCHED','3_WAY_MATCHED','VARIANCE_FLAGGED')`.
* **`supplier_invoice_lines`**: Line-level matching to Goods Receipt Lines and PO Lines.
  - Posts: **Dr GRNI Clearing, Dr GST Receivable, Dr/Cr Price Variance, Cr Accounts Payable**.
* **`payment_proposals` & `payment_proposal_items`**: Proposed disbursement lists for approval.
* **`payment_batches`**: Approved disbursement batches.
  - Generates Australian Banking Association (**ABA**) files for direct batch upload.
* **`supplier_payments`**: Executed payment records.
  - Posts: **Dr Accounts Payable, Cr Payment Clearing Account**.
* **`expense_claims` & `expense_claim_lines`**: Employee out-of-pocket claims and corporate credit card expenses.

---

### Domain 8: Banking Subledger & Automated Reconciliation
Bridges external banking reality to internal cash and clearing ledgers.

* **`bank_accounts`**: Entity-owned bank accounts mapped to GL Cash and Payment Clearing accounts.
* **`bank_statements`**: Feed batches or uploaded statement files.
* **`bank_statement_lines`**: Immutable transaction lines from external feeds (`amount`, `fitid`, `counterparty`, `description`).
* **`bank_reconciliation_sessions`**: Periodic reconciliation workspaces (`statement_balance`, `gl_balance`, `unreconciled_difference`).
* **`bank_reconciliation_matches`**: Reusable match links (1:1, 1:many, many:1) linking statement lines to open item allocations or ledger entries.
  - When reconciled, posts: **Dr Payment Clearing Account, Cr Cash at Bank**.
* **`bank_feed_rules`**: Automated categorization and pattern-matching rules for bank rules engine.

---

### Domain 9: Tax Engine & Statutory Reporting (AU/NZ BAS)
Calculates and audits consumption taxes (AU/NZ GST) and prepares statutory lodgements.

* **`tax_jurisdictions` & `tax_regimes`**: Legal jurisdictions (AU, NZ, UK, US).
* **`tax_codes`**: Tax codes (`GST-TAXABLE-10%`, `GST-FREE`, `INPUT-TAXED`, `EXEMPT`).
* **`tax_rates`**: Effective-dated percentage rates (`rate = 0.100000`).
* **`tax_lines`**: Transaction line tax ledger.
  - Columns: `id (UUID)`, `entity_id (FK)`, `business_event_id (FK)`, `ledger_entry_id (FK)`, `tax_code_id (FK)`, `tax_date`, `taxable_amount`, `tax_amount`, `recoverable_percentage`, `recoverable_tax_amount`, `non_recoverable_tax_amount`, `bas_label ('G1','G10','G11','1A','1B')`.
* **`tax_returns`**: Statutory BAS/GST returns.
  - Columns: `entity_id (FK)`, `jurisdiction`, `tax_period_name`, `from_date`, `to_date`, `status ('DRAFT','LOCKED','FILED','PAID')`, `total_sales_g1`, `gst_on_sales_1a`, `gst_on_purchases_1b`, `net_gst_payable_refundable`, `payg_withholding_4`, `payg_instalment_5a`, `total_amount_payable_refundable`, `lodgement_reference`.

---

### Domain 10: Inventory Subledger (AASB 102)
Perpetual inventory accounting with strict quantity and valuation layer separation.

* **`inventory_locations`**: Warehouses, retail stores, service vehicles, and in-transit locations.
* **`inventory_cost_pools`**: Costing methods per entity/item category (`FIFO`, `WEIGHTED_AVERAGE`, `SPECIFIC_ID`).
* **`inventory_items`**: Stock on hand balances per location and item.
* **`inventory_movements`**: Immutable log of every physical quantity change.
  - Columns: `id (UUID)`, `entity_id (FK)`, `business_event_id (FK)`, `item_id (FK)`, `location_id (FK)`, `movement_type ('RECEIPT','ISSUE','TRANSFER_OUT','TRANSFER_IN','COUNT_ADJUST','SCRAP')`, `quantity`, `uom_id (FK)`, `unit_cost`, `total_cost`, `occurred_at`.
* **`inventory_cost_layers`**: Valuation tracking layers.
  - Columns: `id (UUID)`, `item_id (FK)`, `location_id (FK)`, `layer_date`, `original_quantity`, `remaining_quantity`, `unit_cost`, `is_depleted`.
* **`inventory_counts` & `inventory_count_lines`**: Stocktake sessions and physical variance reconciliation.
* **`inventory_write_down_allowances`**: Net Realisable Value (NRV) write-down allowance tracking under AASB 102.34.

---

### Domain 11: Fixed Assets & Leases (AASB 116 / AASB 16)
Dual-book asset register and full AASB 16 lease liability / Right-of-Use (ROU) engine.

* **`fixed_assets`**: Asset master registry (tag, serial number, location, custodian, capitalization date, in-service date).
* **`asset_components`**: Componentized asset parts with distinct useful lives.
* **`asset_books`**: Parallel books per asset (`AASB_BOOK` vs `TAX_DEPRECIATION_BOOK`).
  - Columns: `asset_id (FK)`, `book_type`, `cost_basis`, `accumulated_depreciation`, `salvage_value`, `useful_life_months`, `depreciation_method ('STRAIGHT_LINE','DIMINISHING_VALUE')`.
* **`asset_transactions`**: Capitalization, depreciation runs, revaluations, impairments, and disposals.
* **`lease_contracts`**: AASB 16 lease agreements.
  - Columns: `id (UUID)`, `entity_id (FK)`, `lessor_party_id (FK)`, `lease_commencement_date`, `lease_term_months`, `discount_rate (incremental borrowing rate)`, `initial_rou_asset_value`, `initial_lease_liability`.
* **`lease_schedules`**: Amortisation schedules splitting each payment into principal reduction, interest expense unwinding, and ROU depreciation.

---

### Domain 12: Projects, Timesheets & WIP (AASB 15)
Operational project accounting and work-in-progress tracking for professional services and construction.

* **`projects`**: Project master record (`code`, `name`, `client_party_id (FK)`, `billing_type ('TIME_AND_MATERIALS','FIXED_FEE','RETAINER','MILESTONE')`, `project_manager_id (FK)`).
* **`project_phases` & `project_tasks`**: Work breakdown structure.
* **`project_budgets` & `project_budget_lines`**: Planned hours, labour costs, expense allowances, and revenue targets.
* **`timesheets` & `timesheet_lines`**: Employee and contractor time entries with billable/non-billable flags.
* **`project_rates`**: Matrix of internal cost rates vs external billing rates by role, employee, and project.
* **`project_wip_entries`**: Unbilled work-in-progress ledger entries (Contract Assets under AASB 15).

---

### Domain 13: Revenue Recognition Engine (AASB 15 / IFRS 15)
Deterministic 5-step revenue engine enforcing separation of Billing from Revenue.

* **`revenue_contracts`**: Commercial contracts identified under Step 1.
* **`performance_obligations`**: Distinct goods or services identified under Step 2 (`recognition_pattern ('POINT_IN_TIME','OVER_TIME_INPUT','OVER_TIME_OUTPUT','STRAIGHT_LINE')`).
* **`contract_transaction_prices`**: Total transaction price (fixed amounts, variable estimates, discounts) under Step 3.
* **`revenue_allocation_lines`**: Stand-alone selling price (SSP) allocation under Step 4.
* **`revenue_schedules`**: Scheduled revenue release periods.
* **`revenue_recognition_runs`**: Executed revenue events under Step 5.
  - Posts: **Dr Contract Liability (or Dr Contract Asset), Cr Revenue**.

---

### Domain 14: Payroll Integration & HRIS Clearing
Ingests gross payroll summaries from external payroll engines (Employment Hero, KeyPay, Xero) without storing sensitive PII in the core ERP.

* **`payroll_runs`**: External pay run batches.
  - Columns: `id (UUID)`, `entity_id (FK)`, `provider_name`, `external_run_id`, `pay_period_start`, `pay_period_end`, `payment_date`, `gross_wages`, `net_wages`, `payg_withholding`, `superannuation_expense`.
* **`payroll_result_lines`**: Detailed component breakdowns per department/project dimension.
* **`payroll_clearing_balances`**: Tracks balances in liability clearing accounts:
  - Account 2110: `Net Wages Payable`
  - Account 2120: `PAYG Withholding Payable`
  - Account 2130: `Superannuation Guarantee Payable`

---

### Domain 15: Core Accounting Kernel (The Financial Truth)
The deterministic financial core verified in `001_tenant_schema_v2.sql`.

* **`business_events`**: Immutable operational events with SHA-256 tamper-proof payloads.
* **`event_processing_log`**: Processing state per ledger.
* **`accounting_rules` & `accounting_rule_versions`**: Approved, versioned, effective-dated posting templates.
* **`accounting_events`**: Balanced journal header per ledger.
* **`ledger_entries`**: Immutable debit/credit lines storing **Transaction**, **Base**, and **Group Reporting** amounts.
* **`period_balances`**: Pre-aggregated trial balance balances maintained by trigger.
* **`control_events`**: Immutable governance log for non-posting events.

---

### Domain 16: Intercompany & Group Consolidation
Automated multi-entity reconciliation, intercompany mirroring, and group elimination.

* **`intercompany_agreements`**: Trading rules between affiliated subsidiaries.
* **`intercompany_transactions` & `intercompany_mirrors`**: Automatically creates mirror AP bill upon AR invoice issue.
* **`intercompany_matches` & `intercompany_disputes`**: Reconciles sender and receiver balances.
* **`consolidation_runs`**: Month-end consolidation batch execution across a group.
* **`consolidation_elimination_entries`**: Posts elimination journals:
  - Eliminates Intercompany Sales / COGS
  - Eliminates Intercompany AR / AP balances
  - Eliminates unrealized profit in inventory (**Dr Group COGS, Cr Inventory Asset**)
* **`fx_translation_reserves`**: Foreign Currency Translation Reserve (FCTR) equity calculation under AASB 121.

---

### Domain 17: Period Close Workspace & Reconciliations
Replaces the "month-end panic" with continuous, automated close checklists and controls.

* **`close_workspaces`**: Entity close dashboard per period.
* **`close_gate_definitions`**: Catalog of mandatory and optional controls (`AP_READY`, `AR_READY`, `BANK_READY`, `TAX_READY`, `INVENTORY_READY`, `FA_READY`, `FX_REVALUATION_DONE`).
* **`period_close_gates`**: Status of each gate (`NOT_RUN`, `IN_PROGRESS`, `READY`, `WAIVED`).
* **`period_reopen_requests` & `period_reopen_approvals`**: Dual-authorization reopen governance with reason codes.
* **`subledger_reconciliations`**: Automated verification matching subledger sum to GL control account.

---

### Domain 18: Universal Workflow & Approval Engine
Universal state machine managing document approvals based on configurable organizational thresholds.

* **`workflow_definitions`**: Configurable rules by document type and threshold amounts.
* **`workflow_instances`**: Live workflow executions.
* **`approval_requests`**: Approval tickets assigned to specific users or roles.
* **`approval_decisions`**: Immutable record of approval or rejection tied to the document's `lock_version` and cryptographic hash.
* **`delegation_rules`**: Temporary out-of-office delegations.

---

### Domain 19: Evidence, Provenance & Audit Portal
Guarantees unbroken lineage from Financial Statements down to the source PDF.

* **`evidence_files`**: Source files (bills, contracts, bank statements) with SHA-256 cryptographic verification.
* **`audit_log`**: Append-only log recording every insert/update/delete on master records.
* **`auditor_portal_requests`**: Native PBC (Provided by Client) ticket management for external auditors.
* **`auditor_access_log`**: Strict access tracking of external auditor activity.

---

### Domain 20: Integration Perimeter & Event Streaming
High-availability ingress and egress perimeter preventing external failures from impacting the ledger.

* **`inbox_events`**: Incoming webhook buffer with unique idempotency keys.
* **`outbox_events`**: Transactional outbox written inside the posting transaction and published by Temporal.
* **`external_system_mappings`**: Bidirectional ID mapping between HRT Systems and third-party systems (Salesforce, HubSpot, Asana, Monday, ServiceM8).
* **`integration_dead_letters`**: Dead-letter and replay queue for failed webhook transformations.

---

## 3. Physical Schema Migration Execution Strategy

The entire 20-domain data architecture is delivered across five clean, numbered, idempotent PostgreSQL migration files:

```
db/sql/
├── 001_tenant_schema_v2.sql          (Domain 15, Domain 1 partial, Domain 4 partial - Deployed)
├── 002_control_party_banking_tax.sql (Domain 2 partial, Domain 3, Domain 8, Domain 9 - Implemented)
├── 003_sales_purchasing_subledger.sql(Domain 5, Domain 6, Domain 7, Domain 18)
├── 004_inventory_assets_projects.sql (Domain 10, Domain 11, Domain 12, Domain 14)
└── 005_revenue_close_consolidation.sql(Domain 13, Domain 16, Domain 17, Domain 19, Domain 20)
```

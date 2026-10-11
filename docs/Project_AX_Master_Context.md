# Project AX — Consolidated Working Context for Gemini

## Purpose
This file consolidates the current Project AX architecture, product principles, scope, decisions, and latest workflow design so it can be imported into Gemini as project context. Items are a mixture of decisions, recommendations, and open design work; Gemini should distinguish these rather than treating every statement as final.

## Product
Project AX is an accounting/ERP platform by HRT / High-Rate Technologies under Radical TG, founded by Anasta Lu.

Positioning: **Xero-simple on the surface; enterprise-grade accounting underneath; configurable to business needs without changing accounting truth.**

Core principle: design around business and accounting events rather than screens or modules.

### Product principles
1. Zero Soul-Crushing Friction
2. Built by a Practitioner, Not a Committee
3. Make Rocket Science Look Hard Again
4. Continuous Truth Over Month-End Panic
5. Native Integration, Not Taped-Together Modules
6. Compliance as Invisible Architecture
7. Software That Works the Way Accounting Works

Accounting should adhere to standards and should not lower the accounting bar merely to make tax filing easy. Accounting is a business language and AX should support sound accounting fundamentals.

## Core architecture
Business Object → Business Event → Accounting Rule Version → Accounting Event → Subledger → Accounting Entry → GL → TB → Close/Consolidation → FS/Reporting/Audit.

The accounting kernel is independent of UI, API, integrations, AI and workflow. No module owns a separate version of accounting truth.

Business Transaction != Accounting Event != Ledger Entry.

Universal subledger concept across AP, AR, Banking, Payroll, Inventory, Fixed Assets, Projects, Revenue, Tax, Leases and Manufacturing.

Full lineage:
DOCUMENT → BUSINESS EVENT → TRANSACTION → SUBLEDGER → ACCOUNTING EVENT → ACCOUNTING ENTRY → GL → TB → CONSOLIDATION → FS → AUDIT EVIDENCE.

## Immutability
Posted/final accounting is always immutable. No hard deletes for financial history. Corrections use reversal, reclassification or adjustment. Never silently overwrite financial history.

Core DB referential integrity should use foreign keys where appropriate, with RESTRICT rather than cascading deletes in finance. Application validation handles business rules.

Concurrency: optimistic lockVersion for normal edits; PostgreSQL FOR UPDATE for short-lived approval/posting/settlement races; both may be combined.

## Dates / periods / FX
Separate document date, economic/service date, accounting/posting date, payment date and tax date. These can map to different periods.

Long-running schedules need economic period separately from GL posting period.

FX should support transaction/functional/reporting currency, transaction/settlement/closing/average/historical rates, source, rate date/type/version, monetary/non-monetary classification, effective-dated rates and reproducibility.

## Organisation / entities
TENANT = customer environment, not legal entity.

Core concepts: LEGAL_ENTITY, ORG_UNIT, LEDGER, ACCOUNTING_FRAMEWORK, ACCOUNTING_POLICY_PROFILE, ACCOUNTING_CALENDAR, ACCOUNTING_PERIOD, SUBLEDGER_PERIOD_STATUS, CONSOLIDATION_GROUP, CONSOLIDATION_GROUP_MEMBER.

Support monthly, 4-4-5, 4-5-4, 5-4-4, 13-period and custom calendars.

Global IDs immutable; business codes mutable. Tenant consistency should be enforced at DB level where possible.

## External entities / consolidation
Entity modes: NATIVE, EXTERNAL_INTEGRATED, EXTERNAL_IMPORT, CONSOLIDATION_ONLY.

External flow: external batch/dataset/TB/GL → validation → approved trial-balance snapshot → consolidation. Preserve provenance.

ENTITY_SOURCE_CONFIGURATION supports TB_ONLY, GL_JOURNAL, GL_LINE, SUBLEDGER_SUMMARY/DETAIL, FULL_TRANSACTION.

ENTITY_SYSTEM_HISTORY tracks system/source mode over effective dates.

External close states include EXTERNAL_TB_RECEIVED, VALIDATED, APPROVED, ENTITY_CERTIFIED, INTERCOMPANY_CONFIRMED.

## Party / master data
Universal PARTY → PARTY_PERSON / PARTY_ORGANISATION → PARTY_ROLE.

Roles: CUSTOMER, SUPPLIER, EMPLOYEE, CONTRACTOR and others.

Profiles and supporting objects: CUSTOMER_PROFILE, SUPPLIER_PROFILE, EMPLOYEE_PROFILE, ENTITY_PARTY_RELATIONSHIP, ENTITY_PARTY_LINK, PARTY_RELATIONSHIP, PARTY_CONTACT_POINT, ADDRESS, PARTY_ADDRESS, BANK_ACCOUNT, PARTY_BANK_ACCOUNT, BANK_ACCOUNT_CHANGE_REQUEST, PARTY_TAX_REGISTRATION, PARTY_CLASSIFICATION, PARTY_ALIAS, PARTY_EXTERNAL_ID, MASTER_DATA_AUTHORITY.

Support duplicate detection, approval and controlled merge. Sensitive employee data remains in Workforce/Payroll.

## CoA / dimensions
Core objects: CHART_OF_ACCOUNTS, ACCOUNT, ACCOUNT_TYPE, ACCOUNT_HIERARCHY, ACCOUNT_MAPPING, DIMENSION, DIMENSION_VALUE, DIMENSION_HIERARCHY, DIMENSION_ASSIGNMENT, VALID_COMBINATION_RULE, REQUIRED_DIMENSION_RULE, DEFAULT_DIMENSION_RULE, DERIVATION_RULE, GROUP_ACCOUNT_MAPPING, EXTERNAL_ACCOUNT_MAPPING.

Recommended hybrid model: typed references for core/high-value dimensions plus DIMENSION_SET / DIMENSION_SET_MEMBER for configurable dimensions. JSON is projection/cache only, not source of truth. Effective dating and historical reproducibility are required.

## Reporting
Do not query raw operational tables ad hoc for reporting.

Operational DB → Accounting Data Model → Semantic Model → Canonical Metrics → Reports/Dashboards/AI.

Canonical metrics include Revenue, Net Revenue, COGS, Gross Profit, Gross Margin, EBITDA, EBIT, AR, AP, Working Capital, Cash, Free Cash Flow, Project WIP, Contract Asset, Contract Liability, Inventory and Debt.

Need report versioning, reproducibility, saved definitions, exports, dimensional drill-down, security/data scopes, period/version and lineage/explain.

## AI CFO
AI sits above deterministic accounting truth. It can summarize trends, anomalies, bottlenecks, recurring issues, collections performance and forecasts, and explain metrics/lineage. AI must not silently override controls or accounting rules.

## Integration
Trigger → Condition → Transformation → Validation → Object Creation → Accounting Event → Approval → Posting.

Need idempotency, source IDs, versioned mappings, failure handling, dead-letter/replay, reconciliation and audit history.

Examples: Salesforce, HubSpot, Asana, Monday, ServiceM8, payroll providers, banks and payment gateways.

No integration writes directly to GL.

## Security / SoD
Roles, permissions, data scopes, actions, approval authority, segregation of duties, privileged actions and audit logging. Admin configurability cannot bypass accounting invariants.

## Technical direction
Initial preference: modular monolith, PostgreSQL transactional source of truth, deterministic accounting kernel, Temporal only for long-running workflows/integrations, API-first, strong imports/exports, outbox/inbox where useful, avoid premature microservices.

Framework options discussed: Frappe Framework or Laravel + Filament. Frappe is attractive for business-document/no-code configuration; Laravel + Filament is attractive where PostgreSQL/developer control is a priority.

## V1 scope
V1 = **broad financial capability + controlled depth**.

V1: Organisation/Entity; Party/Master Data; CoA/Dimensions; Accounting Kernel; Universal Subledgers; Controls; Workflow; Banking; AR; Billing; AP; Procurement Lite; Expenses; Projects; Time; WIP; basic Revenue Recognition; AU/NZ core Tax; basic Fixed Assets; basic Inventory; basic Intercompany; basic Consolidation; Close; Reconciliation; Reporting; Documents/Evidence; Integrations; Payroll integration only.

Later: full CRM, full project management, native full payroll, manufacturing, full WMS, advanced MRP, advanced treasury, advanced lease management, advanced planning, procurement marketplace, global tax localisation and complex enterprise planning.

## Domain architecture
Modules are domain owners, not isolated mini-apps. Modules communicate through application services/events, not direct cross-module writes.

Examples of ownership:
- AR owns Customer Invoice
- AP owns Supplier Invoice
- Banking owns Bank Transaction
- Projects owns Project
- Assets owns Asset
- Inventory owns Inventory Item/Movement
- Revenue owns Revenue Contract/Schedule
- Accounting Kernel owns accounting interpretation
- GL owns posted financial record
- Reporting owns presentation of financial truth

## Universal workflow
CREATE → VALIDATE → ENRICH → APPROVE → COMMIT BUSINESS EVENT → ACCOUNT → POST → SETTLE/RECONCILE → REPORT → CLOSE.

Not every transaction needs every stage.

Do not use one giant status enum. Separate Workflow Status, Accounting Status, Settlement Status, Fulfilment Status, Tax Status, Reconciliation Status and Evidence Status.

Approval attaches to an object version. Material changes invalidate approval.

Workflow can be configured/switchable globally, by module, object and capability, but disabling workflow cannot disable accounting controls.

## Accounting event model
Every material event should contain/link to EventID, TenantID, EntityID, EventType, EventVersion, SourceType, SourceID, OccurredAt, EffectiveDate, EconomicDate, AccountingDate, TaxDate, Currency, LedgerID, AccountingPeriodID, ActorID, CorrelationID, IdempotencyKey, PreviousEventID, ReasonCode and EvidenceReference.

Event classes:
1. Operational events — what happened in the business.
2. Accounting events — accounting interpretation.
3. Ledger events — actual posting.
4. Control events — governance.

Events are immutable. Corrections create new events.

## Accounting Event Contract
Conceptual fields:
AccountingEventID, SourceEventID, SourceObjectType, SourceObjectID, EntityID, LedgerID, AccountingFrameworkID, AccountingPolicyProfileID, EconomicDate, AccountingDate, TaxDate, AccountingPeriodID, Currency, ExchangeRate, ExchangeRateType, ExchangeRateDate, ExchangeRateSource, SubledgerType, SubledgerTransactionID, AccountingRuleID, AccountingRuleVersion, TaxTreatment, DimensionSetID, Amount, FunctionalAmount, ReportingAmount, DebitCredit or SignedAmount, Status, CreatedAt, CreatedBy.

Accounting rules are versioned and effective-dated. Historical transactions retain their original rule version; historical accounting is not silently recalculated using current rules.

## AP
Supplier Invoice workflow: capture → OCR/data extraction → duplicate detection → validation → matching → approval → prepayment/accrual assessment → accounting → posting → payment → reconciliation → close → audit.

Support PO/non-PO/contract invoices; 2-way and 3-way matching; configurable tolerances; prepayments; accruals; service coverage schedules; catch-up recognition; cutoff controls; open/closed period handling.

PO != AP Invoice.

Goods receipt can create Dr Inventory/Expense, Cr GRNI. Supplier invoice can create Dr Inventory/Expense/Prepayment, Dr GST Receivable, Cr AP. Payment can create Dr AP, Cr Bank/Payment Clearing.

Supplier bank account changes require controlled verification and approval.

## AR / Billing
Billing != Revenue != Cash.

Customer → Contract/Order → Fulfilment/Service → Billing → Invoice → Validation → Revenue Assessment → AR Accounting → Payment → Allocation → Reconciliation → Collections → Close.

Payment allocation supports one-to-one, one-to-many, many-to-one, partials, overpayments, underpayments, unidentified cash, deposits, credits, write-offs, disputes and refunds.

Customer deposits should not automatically become revenue; they may be contract liabilities/deposit liabilities until revenue recognition.

## Banking / reconciliation
Bank Feed → Import → Validate → Deduplicate → Classify → Match → Allocate → Account → Reconcile.

Reusable reconciliation engine: one-to-one, one-to-many, many-to-one, many-to-many, splits, partial, unmatched, write-off, dispute, evidence and approval.

Bank reconciliation != GL reconciliation.

## Inventory
V1 is accounting foundation, not full WMS/MRP.

Support costing by entity/location/category/division/item; FIFO, weighted average, specific identification; standard cost operationally; costing pools separate from warehouses; inventory subledger; quantity/value separation; GRNI; landed costs; retrospective cost adjustments; reservations; transfers/in-transit/intercompany; lots/serial/expiry; counts; negative inventory rules; NRV write-downs; reconciliation/cutoff.

## Fixed assets / leases
Physical asset once, multiple books. Support capitalisation candidates, CWIP, components, useful life/residual/method changes, impairment, revaluation, transfers, disposals and asset-to-GL reconciliation.

Lease architecture should support AASB 16 / IFRS 16 concepts: assessment, exemptions, ROU assets, lease liabilities, schedules, modifications, remeasurement and termination.

## Manufacturing
Later specialist module. Future architecture: actual/standard costing, variances, BOM/routing/versioning, work orders/WIP, labour/machine/overhead, standard rollups, scrap, by-products/joint products, recycling/resource recovery/multiple outputs/yield, batch genealogy, subcontracting, MRP later.

## Workforce / payroll
Separate Workforce Core from Payroll. V1 payroll is integration-first.

Payroll Provider → Payroll Result → Import → Validate → Map → Payroll Subledger → GL → Bank/Liability Reconciliation.

Payroll calculation != payroll accounting. Payroll rate != labour costing rate. Leave balance != financial provision.

Future native payroll should support employment, time, leave, pay runs, earnings/deductions, employer costs, statutory rules, awards/enterprise agreements/contracts, effective rates, penalties/overtime/allowances, rule versioning and simulation.

## Projects
Project is first-class object and dimension. Project → Phase → Task → Activity is optional.

Separate GL account, project, cost code, budget, commitment, actual cost, WIP, billing, revenue, cash and forecast/EAC.

Billing modes: T&M, fixed, milestone, progress, cost-plus, unit, retainer, manual, hybrid.

Native project accounting; full project management can integrate with Asana/Monday/etc.

## Revenue recognition
AASB 15 / IFRS 15 five-step architecture: contract, performance obligations, transaction price, allocation, recognition.

Support point-in-time, over-time, usage, milestone, input, output, straight-line and custom methods; contract asset/liability; modifications; cumulative catch-up; estimates; corrections; refunds; credits; warranties; licences; subscriptions; principal/agent; contract costs.

Billing does not independently determine revenue.

## Tax
Shared Tax Engine → Tax Subledger → Statutory Reporting.

Support jurisdiction/regime/registration/code/rate/effective dating, transaction tax lines, recoverable/nonrecoverable, entity/party/product/location.

Initial AU/NZ scope includes GST, BAS, PAYG, RCTI, withholding, payroll tax, FBT, imports/customs, exports and applicable reverse-charge scenarios. Future deferred/current tax.

## Intercompany / consolidation
Intercompany is V1 because multi-entity is core.

Support sender/receiver/counterparty, mirror transactions, matching, currency/tax/reference, settlement and elimination.

Consolidation supports group, membership, local-to-group mapping, FX translation, eliminations, consolidated TB/P&L/BS and basic NCI. Advanced consolidation later.

## Close / audit
Close flow: Period → Close Workspace → AP/AR/Bank/Payroll/Inventory/FA/Revenue/Tax/Project/IC → Reconciliations → Review → Adjustments → Entity Close → Consolidation → Group Reporting.

Control states: BANK_READY, AP_READY, AR_READY, PAYROLL_READY, INVENTORY_READY, FA_READY, PREPAYMENTS_READY, ACCRUALS_READY, PROJECTS_READY, REVENUE_READY, TAX_READY, IC_READY, CONSOLIDATION_READY.

Control result states: NOT_RUN, DRAFT, PROVISIONAL, READY_FOR_REVIEW, APPROVED, FINAL, STALE.

Downstream calculations must be invalidated when upstream inputs change.

Audit trace: Financial Statement → Report Line → Account → GL → Journal → Accounting Event → Subledger → Business Transaction → Source Document → Approval/Change History.

Need Audit Pack, PBC support, read-only Auditor Portal, scoped/logged access, immutable evidence snapshots, audit adjustments and report/board-pack versions.

## Phase 3A — End-to-End Workflow & Business Event Catalogue

Phase 3A converts domain architecture into executable business processes. The objective is to define what users do, what business events occur, what state changes, what accounting consequence occurs, what controls apply, what approvals are required, how integrations participate, how corrections work, and how transactions reach reporting and close.

### Reference Supplier Invoice workflow
Capture → OCR → Duplicate Detection → Validation → Matching → Approval → Prepayment/Accrual Assessment → Accounting → Posting → Payment → Reconciliation → Close → Audit.

### Reference AR workflow
Customer → Contract/Order → Fulfilment/Service → Billing → Invoice → Validation → Revenue Assessment → AR Accounting → Payment → Allocation → Reconciliation → Collections → Close.

### Reference Banking workflow
Bank Feed → Import → Validate → Deduplicate → Classify → Match → Allocate → Account → Reconcile.

### Reference Inventory workflow
Purchase → Receipt → Inventory → Transfer → Consumption/Sale → Adjustment → Count → Reconciliation.

### Reference Fixed Asset workflow
Purchase → Capitalisation Candidate → Asset Created → Placed in Service → Depreciation → Transfer/Revaluation/Impairment → Disposal.

### Reference Project workflow
Project Created → Budget Approved → Cost Incurred → Time/Expense/Inventory Allocated → WIP/Capitalisation → Billing → Revenue Recognition → Cash → Forecast/EAC → Project Close.

### Reference Revenue workflow
Contract → Performance Obligations → Transaction Price → Allocation → Recognition Schedule → Revenue Recognition → Contract Asset/Liability → Reconciliation.

### Reference Close workflow
Period Open → Subledger Processing → Reconciliations → Adjustments → Control Review → Entity Close → Consolidation → Group Close.

Reopening a closed period is controlled: PeriodClosed → ReopenRequested → ImpactAssessment → Approval → PeriodReopened → Adjustment → Reconciliation → PeriodReclosed.

## Initial V1 business event catalogue
Organisation: LegalEntityCreated, LegalEntityModified, LedgerCreated, AccountingCalendarCreated, AccountingPeriodOpened, AccountingPeriodClosed, AccountingPeriodReopened.

Party: PartyCreated, PartyUpdated, PartyApproved, PartyDeactivated, PartyMerged, PartyBankAccountChanged.

AP: SupplierInvoiceCaptured, SupplierInvoiceValidated, SupplierInvoiceApproved, SupplierInvoiceRejected, SupplierInvoiceAccounted, SupplierInvoicePosted, SupplierPaymentProposed, SupplierPaymentApproved, SupplierPaymentSubmitted, SupplierPaymentConfirmed, SupplierPaymentPosted.

AR: CustomerInvoiceCreated, CustomerInvoiceIssued, CustomerInvoiceCorrected, CreditNoteIssued, PaymentReceived, PaymentAllocated, CustomerRefundRequested, CustomerRefundApproved, CustomerRefundIssued.

Banking: BankTransactionImported, BankTransactionValidated, BankTransactionMatched, BankTransactionAllocated, BankTransactionUnmatched, BankTransactionReclassified, BankAccountReconciled.

Procurement: PurchaseOrderCreated, PurchaseOrderApproved, GoodsReceived, GoodsReturned.

Inventory: InventoryReceived, InventoryTransferred, InventoryIssued, InventoryCounted, InventoryAdjusted, InventoryWrittenDown, InventoryDisposed.

Fixed Assets: AssetCandidateCreated, AssetCapitalised, AssetPlacedInService, DepreciationCalculated, DepreciationPosted, AssetTransferred, AssetImpaired, AssetRevalued, AssetDisposed.

Projects: ProjectCreated, ProjectBudgetApproved, TimeEntered, TimeApproved, ExpenseAllocated, ProjectCostIncurred, ProjectWIPCreated, ProjectBilled, ProjectVariationApproved, ProjectClosed.

Revenue: RevenueContractCreated, PerformanceObligationCreated, RevenueScheduleCreated, RevenueRecognised, RevenueDeferred, RevenueReleased, RevenueScheduleModified, RevenueCatchUpRecognised.

Tax: TaxDetermined, TaxAdjusted, TaxReviewed, TaxReturnPrepared, TaxReturnFinalised, TaxReturnFiled.

Payroll: PayrollResultImported, PayrollResultValidated, PayrollAccountingCreated, PayrollPosted, PayrollReconciled.

Intercompany: IntercompanyTransactionCreated, IntercompanyMirrorCreated, IntercompanyMatched, IntercompanyDisputed, IntercompanySettled, IntercompanyEliminated.

Consolidation: EntityCertified, ConsolidationStarted, TranslationCompleted, ConsolidationAdjustmentCreated, ConsolidationFinalised.

Close: CloseControlCalculated, CloseControlFailed, CloseControlApproved, EntityCloseStarted, EntityCloseCompleted, GroupCloseStarted, GroupCloseCompleted.

## Phase 3A acceptance criteria
For every V1 financial process, AX must answer:
1. What business event occurred?
2. Who/what created it?
3. What object changed?
4. What version changed?
5. What approval was required?
6. What accounting rule applies?
7. What accounting date applies?
8. What period applies?
9. What tax treatment applies?
10. What subledger is affected?
11. What GL entries result?
12. What dimensions are required?
13. What evidence exists?
14. How can the transaction be corrected?
15. How is it reconciled?
16. How does it affect close?
17. How does it appear in reporting?
18. Can an auditor trace it to source evidence?
19. Can the same event safely be replayed?
20. Can the system prove it was not silently changed?

## Next phase: Phase 3B
Build the actual Accounting Event Matrix for approximately 30–50 V1 events.

For every event define: event, source object, subledger, debit, credit, tax, dimensions, economic date, accounting date, period, accounting rule, approval, reconciliation, reversal/correction, evidence, reporting effect and close dependency.

The matrix should become the executable specification for the accounting kernel, not merely documentation.

## SDLC roadmap
1. Vision / Market / Requirements
2. Domain & Accounting Architecture
3. Technical Architecture
4. Data Architecture
5. Module / Business Process Architecture
6. Security / Controls / Compliance
7. UX / UI Architecture
8. API / Integration Architecture
9. Reporting / Analytics / Semantic Model
10. AI Architecture
11. Testing / Accounting Validation
12. Migration / Implementation
13. Deployment / DevOps / Observability
14. Operations / Support / Release Management

## Working instruction for Gemini
Treat this file as consolidated Project AX working context. Challenge assumptions, identify omissions and contradictions, and distinguish explicit decisions from recommendations/open questions. Preserve the core invariant that posted financial history is immutable and all accounting ultimately passes through the central accounting kernel. Do not redesign the system around screens merely for convenience. Prefer rigorous accounting architecture, explainability, auditability, configurability and practical SME usability.

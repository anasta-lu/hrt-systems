# Phase 3B: Accounting Event Matrix (Part 4: Reversals, FX & Consolidation)

This matrix maps the fourth batch of events for the HRT Systems accounting kernel, focusing on Exceptions (Credit Notes, Write-Downs), automated Multi-Currency Revaluations, and Group Consolidations.

---

## 16. Event: `CreditNoteIssued`
*When a business must reduce the amount a customer owes due to a dispute, return, or pricing error.*

*   **Source Object:** `CustomerCreditNote`
*   **Subledger:** Accounts Receivable (AR)
*   **Debit:** Sales Revenue (Income - Contra) AND Tax/GST Payable (Liability - Contra)
*   **Credit:** Accounts Receivable (Asset)
*   **Tax:** Reverses the exact tax component originally charged on the disputed lines.
*   **Dimensions:** `Customer` (Header), `Project` / `Department` (Line level - must match the original invoice if applicable).
*   **Economic Date:** The date the return/dispute was accepted.
*   **Accounting Date:** The date the credit note is issued.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `AR_Credit_Recognition_v1`
*   **Approval:** Requires Manager/Controller approval if the credit exceeds configured thresholds.
*   **Reconciliation:** The AR subledger applies this credit against an open invoice or holds it on the customer's account as unallocated.
*   **Reversal/Correction:** `CreditNoteVoided`.
*   **Evidence:** Customer correspondence / Return Merchandise Authorization (RMA).
*   **Reporting Effect:** Decreases Gross Revenue; Decreases AR.
*   **Close Dependency:** Must be processed before `AR_READY`.

---

## 17. Event: `InventoryWrittenDown`
*When physical inventory is lost, damaged, stolen, or deemed obsolete (Net Realisable Value adjustment).*

*   **Source Object:** `InventoryAdjustment` / `StockCount`
*   **Subledger:** Inventory
*   **Debit:** Inventory Shrinkage / Write-Down (Expense / COGS)
*   **Credit:** Inventory Asset (Balance Sheet)
*   **Tax:** N/A
*   **Dimensions:** `Location` / `Warehouse`, `Item_Category`.
*   **Economic Date:** The date the physical count occurred or damage was discovered.
*   **Accounting Date:** The date the adjustment is approved.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `Inventory_Impairment_v1`
*   **Approval:** Requires Warehouse Manager or Financial Controller approval.
*   **Reconciliation:** Aligns the system inventory subledger with the physical reality.
*   **Reversal/Correction:** `InventoryAdjustmentReversed`.
*   **Evidence:** Approved Stock Count Variance Report.
*   **Reporting Effect:** Decreases Profit (via Expense); Decreases Total Assets.
*   **Close Dependency:** Must be processed before `INVENTORY_READY`.

---

## 18. Event: `FXRevaluationCalculated` (Month-End)
*An automated event that revalues all unpaid foreign currency invoices/bills and foreign bank accounts to the month-end spot rate (AASB 121 compliance).*

*   **Source Object:** `FXRevaluationRun`
*   **Subledger:** AR / AP / Banking / GL
*   **Debit/Credit:** Unrealized FX Loss (Expense) OR Unrealized FX Gain (Income)
*   **Debit/Credit:** AR / AP / Bank (Asset/Liability adjustment)
*   **Tax:** N/A (Unrealized FX is generally not a taxable event until realized).
*   **Dimensions:** Inherited from the underlying foreign currency transactions.
*   **Economic Date:** The last day of the month.
*   **Accounting Date:** The last day of the month.
*   **Period:** The period being closed.
*   **Accounting Rule:** `AASB121_Unrealized_Revaluation_v1`
*   **Approval:** System-generated as part of the Period Close workflow.
*   **Reconciliation:** Ensures the base-currency value of foreign AP/AR accurately reflects the current exchange rate on the Balance Sheet.
*   **Reversal/Correction:** The system automatically posts a reversing journal on Day 1 of the following month, so the final Realized FX can be calculated accurately when the payment actually clears.
*   **Evidence:** System FX Rate Table snapshot on month-end date.
*   **Reporting Effect:** Adjusts Assets/Liabilities; Hits the PnL as an Unrealized Gain/Loss.
*   **Close Dependency:** Must be run *after* all operational subledgers are locked, but *before* `EntityCloseCompleted`.

---

## 19. Event: `EntityCertified`
*A major control event indicating a single subsidiary/entity has completely locked its books and is ready to be rolled up into the Parent Consolidation Group.*

*   **Source Object:** `EntityCloseWorkspace`
*   **Subledger:** N/A (GL Control Event)
*   **Debit:** N/A
*   **Credit:** N/A
*   **Tax:** N/A
*   **Dimensions:** N/A
*   **Economic Date:** N/A
*   **Accounting Date:** The last day of the period.
*   **Period:** The target period ID.
*   **Accounting Rule:** `Entity_Certification_Gate_v1`
*   **Approval:** Requires explicit sign-off by the Entity Financial Controller.
*   **Reconciliation:** Ensures the Local Trial Balance is perfectly balanced and all subledgers are locked.
*   **Reversal/Correction:** `EntityDecertified` (Requires Parent Group CFO override).
*   **Evidence:** Signed Entity Close Checklist.
*   **Reporting Effect:** Flags the entity's Trial Balance as "Ready for Group Extraction."
*   **Close Dependency:** Triggers the start of `ConsolidationStarted`.

---

## 20. Event: `ConsolidationAdjustmentCreated`
*A top-level journal entry posted explicitly at the Consolidation Group level, often used to eliminate Intercompany profit, investments, or align differing accounting standards (e.g., local GAAP to IFRS).*

*   **Source Object:** `ConsolidationJournal`
*   **Subledger:** N/A (Group Ledger)
*   **Debit/Credit:** Various (e.g., Dr Intercompany Revenue, Cr Intercompany COGS, Dr Inventory to eliminate markup).
*   **Tax:** Often has deferred tax implications depending on the elimination.
*   **Dimensions:** `Consolidation_Group`, `Counterparty_Entity`.
*   **Economic Date:** N/A
*   **Accounting Date:** The last day of the period.
*   **Period:** The target period ID.
*   **Accounting Rule:** `Group_Elimination_v1`
*   **Approval:** Group Financial Controller / Group CFO.
*   **Reconciliation:** Adjustments are applied *on top* of the aggregated Entity Trial Balances to produce the final Consolidated Financial Statements. They never push down into the local entity books.
*   **Reversal/Correction:** `ConsolidationAdjustmentCorrected`.
*   **Evidence:** Group Elimination Working Papers.
*   **Reporting Effect:** Ensures Group Revenue/Profit is not artificially inflated by subsidiaries selling to each other.
*   **Close Dependency:** Must be processed before `GroupCloseCompleted`.

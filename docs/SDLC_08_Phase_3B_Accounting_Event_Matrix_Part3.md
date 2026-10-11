# Phase 3B: Accounting Event Matrix (Part 3: Intercompany, Projects & Control Events)

This matrix continues the executable specification for the HRT Systems accounting kernel, focusing on multi-entity Intercompany flows, Project Costing, Bank Reconciliation, Tax, and the Month-End Close.

---

## 11. Event: `IntercompanyTransactionCreated`
*When an entity incurs an expense or transfers cash on behalf of a sister entity within the same Consolidation Group.*

*   **Source Object:** `IntercompanyJournal` / `SupplierInvoice`
*   **Subledger:** Intercompany (IC) / General Ledger
*   **Debit:** Intercompany Receivable - Entity B (Asset in Entity A)
*   **Credit:** Bank / Accounts Payable / Expense (Asset/Liability in Entity A)
*   **Tax:** Evaluated for applicable IC GST/VAT (can often be out of scope or subject to specific group rules).
*   **Dimensions:** `Counterparty_Entity`, `Project`.
*   **Economic Date:** Date the cross-charge occurred.
*   **Accounting Date:** Date of the journal.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `Intercompany_CrossCharge_v1`
*   **Approval:** Requires explicit approval to prevent out-of-balance IC ledgers. System instantly generates the `IntercompanyMirrorCreated` event in Entity B (Dr Expense, Cr Intercompany Payable - Entity A).
*   **Reconciliation:** IC Receivable in Entity A must exactly match IC Payable in Entity B.
*   **Reversal/Correction:** `IntercompanyDisputed` or `IntercompanyTransactionCorrected`.
*   **Evidence:** Intercompany Agreement / Shared Service Allocation Schedule.
*   **Reporting Effect:** Increases IC Assets/Liabilities on standalone books; perfectly eliminates to $0 on the Consolidated Group Balance Sheet.
*   **Close Dependency:** Must be processed before `IC_READY` and `CONSOLIDATION_READY`.

---

## 12. Event: `BankTransactionMatched`
*The event where a raw, imported bank feed line is officially reconciled against a system ledger transaction.*

*   **Source Object:** `BankReconciliationMatch`
*   **Subledger:** Banking
*   **Debit:** N/A (This is a *Control Event*, it typically does not generate new GL entries unless it triggers a bank fee or minor write-off).
*   **Credit:** N/A
*   **Tax:** N/A
*   **Dimensions:** N/A (Inherits from the underlying matched transaction).
*   **Economic Date:** The bank statement date.
*   **Accounting Date:** The date the match is finalized.
*   **Period:** Derived from the bank statement date.
*   **Accounting Rule:** `Bank_Match_Verification_v1`
*   **Approval:** Handled by the user in the Bank Rec UI, or auto-approved via exact-match rules.
*   **Reconciliation:** Changes the status of the underlying system transaction (e.g., `SupplierPaymentPosted`) from *Unreconciled* to *Reconciled*.
*   **Reversal/Correction:** `BankTransactionUnmatched`.
*   **Evidence:** Bank Feed Line ID.
*   **Reporting Effect:** Validates the Cash balance. Unmatched items form the "Outstanding Checks/Deposits" on the Bank Reconciliation Report.
*   **Close Dependency:** Must be processed before `BANK_READY`.

---

## 13. Event: `ProjectCostIncurred`
*When an expense, timesheet, or inventory issue is tagged to a specific project, updating the WIP or Cost of Goods Sold.*

*   **Source Object:** `Timesheet` / `ExpenseClaim` / `SupplierInvoice`
*   **Subledger:** Projects
*   **Debit:** Project WIP (Asset) OR Project COGS (Expense)
*   **Credit:** Wages Payable / AP / Inventory (Liability/Asset)
*   **Tax:** Inherits from the source document.
*   **Dimensions:** `Project` (Mandatory), `Task`, `Employee`.
*   **Economic Date:** Date the time was worked or expense incurred.
*   **Accounting Date:** Date the source document was approved.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `Project_Cost_Capitalisation_v1` (Determines if the cost hits the PnL immediately or sits on the Balance Sheet as WIP).
*   **Approval:** Timesheet or Expense Claim approval by Project Manager.
*   **Reconciliation:** Project Subledger costs must tie to GL WIP or COGS accounts.
*   **Reversal/Correction:** `ProjectCostReclassified` (Moves cost to a different project).
*   **Evidence:** Approved Timesheet / Receipt.
*   **Reporting Effect:** Increases WIP (Asset) or decreases Profit via COGS; updates Project Profitability metrics.
*   **Close Dependency:** Must be processed before `PROJECTS_READY`.

---

## 14. Event: `TaxDetermined`
*A control event representing the finalization of the tax liability for a given filing period (e.g., a BAS or VAT return).*

*   **Source Object:** `TaxReturn`
*   **Subledger:** Tax
*   **Debit:** GST/VAT Collected (Liability clearing)
*   **Credit:** GST/VAT Paid (Asset clearing) AND Tax Authority Payable (Final Liability)
*   **Tax:** N/A (This *is* the tax settlement).
*   **Dimensions:** `Jurisdiction` (e.g., AU-ATO), `Tax_Regime`.
*   **Economic Date:** The end of the tax period (e.g., March 31 for Q1 BAS).
*   **Accounting Date:** The end of the tax period.
*   **Period:** The specific tax reporting period.
*   **Accounting Rule:** `Tax_Return_Settlement_v1`
*   **Approval:** Requires explicitly marked `TaxReturnFinalised` by the Tax Manager/Accountant.
*   **Reconciliation:** Clears the transactional tax accounts and moves the net balance to a single Payable/Receivable account for the Tax Authority.
*   **Reversal/Correction:** `TaxAdjusted` (Creates a prior-period adjustment for the next return).
*   **Evidence:** Exported statutory tax return (e.g., ATO BAS XML payload).
*   **Reporting Effect:** Clears multiple gross tax accounts into a single net liability/asset.
*   **Close Dependency:** Must be processed before `TAX_READY`.

---

## 15. Event: `AccountingPeriodClosed`
*The ultimate control event that enforces immutability for a specific accounting period.*

*   **Source Object:** `AccountingPeriod`
*   **Subledger:** General Ledger (GL)
*   **Debit:** N/A (Control Event).
*   **Credit:** N/A
*   **Tax:** N/A
*   **Dimensions:** N/A
*   **Economic Date:** N/A
*   **Accounting Date:** The last day of the accounting period being closed.
*   **Period:** The target period ID.
*   **Accounting Rule:** `Period_Close_Lock_v1`
*   **Approval:** Requires Financial Controller / CFO approval. All underlying control states (`AP_READY`, `BANK_READY`, etc.) must equal `APPROVED` or `FINAL`.
*   **Reconciliation:** Verifies Trial Balance debits = credits.
*   **Reversal/Correction:** `AccountingPeriodReopened` (Requires massive elevated privileges and logs an audit exception).
*   **Evidence:** System-generated Close Pack (Trial Balance Snapshot).
*   **Reporting Effect:** Locks all reporting for the period. Any new transactions with an Accounting Date in this period are forcefully pushed to the next open period.
*   **Close Dependency:** This *is* the final close action.

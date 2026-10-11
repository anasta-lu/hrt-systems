# Phase 3B: Accounting Event Matrix (Part 2: Advanced Events)

*Note: The platform formerly known as Project AX is now officially designated as HRT Systems.*

This matrix continues the executable specification for the HRT Systems accounting kernel, focusing on Payroll, Inventory, Revenue Recognition, and Fixed Assets.

---

## 6. Event: `PayrollResultAccounted`
*The integration event triggered when an external HRIS/Payroll system (e.g., Employment Hero) finalizes a pay run.*

*   **Source Object:** `PayrollResultImport`
*   **Subledger:** Payroll (or directly to GL if lowest tier)
*   **Debit:** Wages & Salaries (Expense) AND Superannuation/KiwiSaver (Expense)
*   **Credit:** PAYG/PAYE Withholding (Liability), Superannuation Payable (Liability), and Net Wages Clearing (Liability)
*   **Tax:** N/A (Taxes are strictly statutory liabilities calculated by the external HRIS).
*   **Dimensions:** `Employee` (Line level), `Department` / `Project` (Line level splitting based on timesheets).
*   **Economic Date:** The pay period end date (when the labor was performed).
*   **Accounting Date:** The payroll finalization date.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `Payroll_Expense_Recognition_v1`
*   **Approval:** Approved in external HRIS; mapped and accepted via Temporal integration.
*   **Reconciliation:** Net Wages Clearing account must zero out when the physical cash leaves the bank (`PayrollReconciled`).
*   **Reversal/Correction:** `PayrollResultReversed` (Requires re-import from HRIS).
*   **Evidence:** Payroll Summary ID / Timesheet API Payload.
*   **Reporting Effect:** Increases Expenses (reduces Net Profit); Increases Liabilities.
*   **Close Dependency:** Must be processed before `PAYROLL_READY`.

---

## 7. Event: `InventoryReceived` (Goods Receipt Not Invoiced - GRNI)
*The event when physical goods arrive at the warehouse, but the supplier has not yet sent the invoice.*

*   **Source Object:** `GoodsReceiptNote` (GRN)
*   **Subledger:** Inventory
*   **Debit:** Inventory Asset (Balance Sheet)
*   **Credit:** GRNI / Uninvoiced Receipts (Liability clearing account)
*   **Tax:** N/A (Tax is recognized when the actual Supplier Invoice is processed).
*   **Dimensions:** `Location` / `Warehouse`, `Item_Category`.
*   **Economic Date:** The date the physical goods crossed the loading dock.
*   **Accounting Date:** Date of receipt.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `Inventory_Accrual_v1` (using Standard Cost or PO estimated cost).
*   **Approval:** Warehouse manager receives goods against an approved Purchase Order.
*   **Reconciliation:** GRNI account clears when `SupplierInvoiceAccounted` is processed.
*   **Reversal/Correction:** `GoodsReturned` (Reverses Dr Inventory, Cr GRNI).
*   **Evidence:** Signed Bill of Lading / Digital Goods Receipt.
*   **Reporting Effect:** Increases Assets (Inventory); Increases Liabilities (GRNI). No PnL impact yet.
*   **Close Dependency:** Must be processed before `INVENTORY_READY` and `AP_READY`.

---

## 8. Event: `RevenueRecognised` (Amortization of Unearned Revenue)
*The event triggered by the Revenue Engine to recognize revenue over time (e.g., a SaaS subscription or milestone completion).*

*   **Source Object:** `RevenueSchedule` / `PerformanceObligation`
*   **Subledger:** Revenue
*   **Debit:** Customer Deposits / Unearned Revenue (Liability)
*   **Credit:** Realized Sales Revenue (Income)
*   **Tax:** N/A (Usually handled at initial invoicing/deposit).
*   **Dimensions:** `Customer`, `Project`.
*   **Economic Date:** The period the service was actively rendered (e.g., Day 1 to Day 30 of the month).
*   **Accounting Date:** Usually month-end.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `AASB15_OverTime_Recognition_v1`
*   **Approval:** Automated by the Revenue Engine based on the active contract schedule.
*   **Reconciliation:** The Unearned Revenue liability account burns down to zero over the life of the contract.
*   **Reversal/Correction:** `RevenueCatchUpRecognised` (If contract terms are modified mid-flight).
*   **Evidence:** Revenue Contract Schedule ID.
*   **Reporting Effect:** Decreases Liability; Increases Gross Profit.
*   **Close Dependency:** Must be processed before `REVENUE_READY`.

---

## 9. Event: `AssetCapitalised`
*The event when a physical purchase (e.g., machinery) or a WIP project is officially moved onto the Fixed Asset register.*

*   **Source Object:** `AssetCandidate` / `CapitalisationJournal`
*   **Subledger:** Fixed Assets (FA)
*   **Debit:** Property, Plant & Equipment (Fixed Asset)
*   **Credit:** Capital WIP (Asset Clearing) OR Expense (if transferring from an immediate write-off).
*   **Tax:** N/A.
*   **Dimensions:** `Location`, `Department`, `Asset_Class`.
*   **Economic Date:** Placed in Service date.
*   **Accounting Date:** Date of capitalization decision.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `Asset_Capitalisation_v1`
*   **Approval:** Requires Finance Manager / Controller approval based on capitalization thresholds.
*   **Reconciliation:** Asset Subledger cost basis ties to GL PPE account.
*   **Reversal/Correction:** `AssetTransferred` or `AssetCapitalisationReversed`.
*   **Evidence:** Asset Tag ID / Final Inspection Sign-off.
*   **Reporting Effect:** Moves balance from short-term Asset/Expense to Long-Term Asset.
*   **Close Dependency:** Must be processed before `FA_READY`.

---

## 10. Event: `DepreciationPosted`
*The automated month-end event recognizing the wear-and-tear of a capitalized asset.*

*   **Source Object:** `AssetDepreciationSchedule`
*   **Subledger:** Fixed Assets (FA)
*   **Debit:** Depreciation Expense (PnL)
*   **Credit:** Accumulated Depreciation (Contra-Asset)
*   **Tax:** N/A (Deferred tax implications calculated separately).
*   **Dimensions:** `Location`, `Department`, `Asset_Class` (Inherited from the parent asset).
*   **Economic Date:** The specific month the depreciation covers.
*   **Accounting Date:** Last day of the month.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `StraightLine_Depreciation_v1` (or Diminishing Value based on asset book).
*   **Approval:** Automated system run at month-end.
*   **Reconciliation:** FA Subledger Net Book Value (NBV) ties to GL (PPE minus Accumulated Depr).
*   **Reversal/Correction:** `AssetImpaired` or `DepreciationRecalculated` (if useful life changes).
*   **Evidence:** System-generated depreciation run log.
*   **Reporting Effect:** Increases Expenses (lowers Net Profit); Decreases Total Assets (NBV).
*   **Close Dependency:** Must be processed before `FA_READY`.

# Phase 3B: Accounting Event Matrix (Part 5: Procurement, Employee Expenses & Exceptions)

This matrix maps the fifth batch of events for the HRT Systems accounting kernel, focusing on Commitments (Purchase Orders), Employee Expense Claims, Automated Amortization, and strict Reversal/Control events.

---

## 21. Event: `PurchaseOrderApproved`
*When a commitment is made to a supplier to purchase goods or services. This is a critical budget-control event.*

*   **Source Object:** `PurchaseOrder`
*   **Subledger:** Procurement (Commitments)
*   **Debit/Credit:** N/A for standard financial accounting. (If using encumbrance accounting for non-profits/government, Dr Encumbrance, Cr Reserve for Encumbrance).
*   **Tax:** N/A (Tax is recognized upon invoicing or receipt).
*   **Dimensions:** `Project`, `Department`, `Location`.
*   **Economic Date:** N/A
*   **Accounting Date:** The date the PO is fully approved.
*   **Period:** N/A
*   **Accounting Rule:** `PO_Commitment_Tracking_v1`
*   **Approval:** Requires a robust hierarchical approval matrix (e.g., Line Manager -> Department Head -> CFO) based on the dollar value.
*   **Reconciliation:** Forms the "Committed Spend" column on Budget vs. Actuals reports.
*   **Reversal/Correction:** `PurchaseOrderCancelled` or `PurchaseOrderAmended`.
*   **Evidence:** Digitally signed PO snapshot.
*   **Reporting Effect:** Reduces the "Available Budget" for a specific department or project, but does not impact the PnL or Balance Sheet yet.
*   **Close Dependency:** N/A

---

## 22. Event: `ExpenseClaimAccounted`
*When an employee submits an out-of-pocket expense for reimbursement.*

*   **Source Object:** `EmployeeExpenseClaim`
*   **Subledger:** Accounts Payable (AP - Employee as Supplier)
*   **Debit:** Travel / Meals / Supplies (Expense) AND Tax/GST Receivable (Asset)
*   **Credit:** Employee Reimbursement Payable (Liability)
*   **Tax:** Calculated per line item based on receipt tax codes.
*   **Dimensions:** `Employee` (Header), `Project` / `Department` (Line level).
*   **Economic Date:** The date on the physical receipt.
*   **Accounting Date:** The date the claim is approved by management.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `Employee_Expense_Recognition_v1`
*   **Approval:** Line Manager approval required. (Optionally flags for Finance review if it breaches company policy limits).
*   **Reconciliation:** Ties into the AP subledger; cleared when the physical cash is reimbursed to the employee.
*   **Reversal/Correction:** `ExpenseClaimRejected` (Before posting) or `ExpenseClaimCorrected`.
*   **Evidence:** OCR snapshot of the uploaded physical receipt.
*   **Reporting Effect:** Decreases Profit (via Expense); Increases Liabilities.
*   **Close Dependency:** Must be processed before `AP_READY` and `TAX_READY`.

---

## 23. Event: `PrepaymentAmortised`
*The automated month-end event recognizing the burn-down of a prepaid expense (e.g., a 12-month software subscription paid upfront).*

*   **Source Object:** `PrepaymentSchedule`
*   **Subledger:** Prepayments / GL
*   **Debit:** Software / Insurance (Expense)
*   **Credit:** Prepaid Expenses (Asset)
*   **Tax:** N/A (Tax was fully claimed on the initial AP Bill).
*   **Dimensions:** `Department`, `Project`, `Location` (Inherited from the original bill).
*   **Economic Date:** The specific month being amortized.
*   **Accounting Date:** Last day of the month.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `StraightLine_Amortization_v1`
*   **Approval:** Automated system run at month-end.
*   **Reconciliation:** The Prepaid Expense asset account mathematically burns down to exactly zero over the schedule's lifespan.
*   **Reversal/Correction:** `PrepaymentScheduleAdjusted` (e.g., if a subscription is cancelled early and refunded).
*   **Evidence:** System-generated amortization run log.
*   **Reporting Effect:** Increases Expenses (lowers Net Profit); Decreases Assets.
*   **Close Dependency:** Must be processed before `PREPAYMENTS_READY`.

---

## 24. Event: `PaymentBounced` (Dishonored Receipt)
*An exception event where a customer's payment (previously recorded as received) is dishonored by the bank (e.g., insufficient funds or chargeback).*

*   **Source Object:** `BankTransaction` (Dishonor Notice)
*   **Subledger:** Banking / Accounts Receivable (AR)
*   **Debit:** Accounts Receivable (Asset - Re-establishing the debt)
*   **Credit:** Bank Account (Asset - Reversing the false deposit)
*   **Tax:** N/A
*   **Dimensions:** `Customer`.
*   **Economic Date:** The date the bank reversed the funds.
*   **Accounting Date:** The date the bank reversed the funds.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `AR_Payment_Reversal_v1`
*   **Approval:** Handled during Bank Reconciliation.
*   **Reconciliation:** Automatically un-allocates the payment from the Customer Invoice, returning the invoice to an `Overdue` status to trigger automated Debt Collection workflows.
*   **Reversal/Correction:** N/A (This event *is* a correction).
*   **Evidence:** Bank Feed Dishonor Code.
*   **Reporting Effect:** Decreases Cash; Increases AR.
*   **Close Dependency:** Must be processed before `BANK_READY` and `AR_READY`.

---

## 25. Event: `AccountingPeriodReopened`
*A highly restricted control event that breaks the immutability of a closed period to allow a late audit adjustment.*

*   **Source Object:** `PeriodReopenRequest`
*   **Subledger:** General Ledger (GL Control)
*   **Debit/Credit:** N/A
*   **Tax:** N/A
*   **Dimensions:** N/A
*   **Economic Date:** N/A
*   **Accounting Date:** Timestamp of the action.
*   **Period:** The target period being reopened.
*   **Accounting Rule:** `Emergency_Period_Reopen_v1`
*   **Approval:** Requires dual-authorization (e.g., CFO + Audit Partner approval) accompanied by a mandatory `ReasonCode` (e.g., "Year-End Audit Adjustment").
*   **Reconciliation:** Downstream control states (e.g., Consolidations, Retained Earnings roll-forwards) are instantly flagged as `STALE` and must be recalculated.
*   **Reversal/Correction:** `AccountingPeriodClosed` (Re-locking it after the adjustment is made).
*   **Evidence:** Mandatory digital signature and reason log.
*   **Reporting Effect:** Removes the "Finalized" watermark from financial reports for that period.
*   **Close Dependency:** Invalidates the Close.

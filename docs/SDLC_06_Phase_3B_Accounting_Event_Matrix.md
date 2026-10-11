# Phase 3B: Accounting Event Matrix (Part 1: Foundational Events)

This document acts as the executable specification for the Project AX accounting kernel. It defines exactly how operational business events are interpreted by the accounting rules engine to generate immutable ledger entries.

---

## 1. Event: `CustomerInvoiceIssued`
*The core event triggering the recognition of standard sales and taxes owed to the business.*

*   **Source Object:** `CustomerInvoice`
*   **Subledger:** Accounts Receivable (AR)
*   **Debit:** Accounts Receivable (Asset control account)
*   **Credit:** Sales Revenue (Income) AND Tax/GST Payable (Liability)
*   **Tax:** Calculated per line item based on Tax Rule engine (e.g., GST on Income).
*   **Dimensions:** `Customer` (Header), `Project` / `Department` / `Location` (Line level).
*   **Economic Date:** The date the service was actually delivered (used for rev-rec mapping).
*   **Accounting Date:** The date the invoice is issued and legally enforceable.
*   **Period:** Automatically derived by mapping the Accounting Date to the `ACCOUNTING_CALENDAR`.
*   **Accounting Rule:** `AR_Recognition_Rule_v1`
*   **Approval:** Cannot be generated until the source invoice reaches `APPROVED` status.
*   **Reconciliation:** AR Subledger balance must perfectly tie to the GL AR Control Account.
*   **Reversal/Correction:** Generates `CustomerInvoiceCorrected` (Full Reversal: Cr AR, Dr Rev, Dr Tax, followed by new event).
*   **Evidence:** Immutable PDF snapshot of the issued invoice and `CustomerContract`.
*   **Reporting Effect:** Increases Gross Revenue (PnL); Increases AR / Working Capital (Balance Sheet).
*   **Close Dependency:** Must be processed before `AR_READY` and `TAX_READY`.

---

## 2. Event: `PaymentReceived`
*The receipt of cash from a customer, clearing the AR balance.*

*   **Source Object:** `BankTransaction` / `PaymentAllocation`
*   **Subledger:** Banking / Accounts Receivable (AR)
*   **Debit:** Bank Account (Asset)
*   **Credit:** Accounts Receivable (Asset control account)
*   **Tax:** N/A (Handled at invoice level, unless cash-basis accounting is toggled).
*   **Dimensions:** `Customer` (Header), `Bank_Account` (Header).
*   **Economic Date:** Date funds cleared the bank.
*   **Accounting Date:** Date funds cleared the bank (Statement Date).
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `AR_Payment_Clearing_v1`
*   **Approval:** Automated if matched 1:1 via Bank Feed; Manual approval if allocated across multiple invoices with short-pays.
*   **Reconciliation:** Clears the open invoice in the AR Subledger. Bank balance ties to GL Bank Account.
*   **Reversal/Correction:** Generates `PaymentUnallocated` or `PaymentBounced` (Dr AR, Cr Bank).
*   **Evidence:** Bank Feed transaction ID / Remittance Advice.
*   **Reporting Effect:** Increases Cash; Decreases AR (Neutral on Total Assets).
*   **Close Dependency:** Must be processed before `BANK_READY` and `AR_READY`.

---

## 3. Event: `SupplierInvoiceAccounted`
*The recognition of an expense or inventory asset, and the liability to pay a supplier.*

*   **Source Object:** `SupplierInvoice` (AP Bill)
*   **Subledger:** Accounts Payable (AP)
*   **Debit:** Expense Account OR Inventory Asset OR Prepayment Asset AND Tax/GST Receivable (Asset)
*   **Credit:** Accounts Payable (Liability control account)
*   **Tax:** Calculated based on supplier tax profile and line item tax codes.
*   **Dimensions:** `Supplier` (Header), `Project` / `Department` / `Location` (Line level).
*   **Economic Date:** The date the expense was incurred or goods received.
*   **Accounting Date:** The supplier's invoice date.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `AP_Recognition_Rule_v1`
*   **Approval:** Requires 2-way or 3-way matching approval (PO -> Receipt -> Invoice) and/or SoD management approval.
*   **Reconciliation:** AP Subledger balance ties to GL AP Control Account.
*   **Reversal/Correction:** Generates `SupplierInvoiceCorrected` or `SupplierCreditNoteIssued`.
*   **Evidence:** OCR Snapshot of original Supplier Invoice PDF.
*   **Reporting Effect:** Decreases Profit (if Expense); Increases AP Liability.
*   **Close Dependency:** Must be processed before `AP_READY` and `TAX_READY`.

---

## 4. Event: `SupplierPaymentPosted`
*The dispersal of cash to settle a supplier liability.*

*   **Source Object:** `SupplierPayment` (Remittance)
*   **Subledger:** Banking / Accounts Payable (AP)
*   **Debit:** Accounts Payable (Liability)
*   **Credit:** Bank Account (Asset)
*   **Tax:** N/A (unless cash-basis).
*   **Dimensions:** `Supplier`, `Bank_Account`.
*   **Economic Date:** Date the payment file (ABA/EFT) is executed.
*   **Accounting Date:** Date the payment clears the bank.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `AP_Payment_Settlement_v1`
*   **Approval:** Requires batch payment authorization (Segregation of Duties).
*   **Reconciliation:** Marks Supplier Invoice as Paid in AP Subledger.
*   **Reversal/Correction:** Generates `PaymentVoided` (Dr Bank, Cr AP).
*   **Evidence:** Bank Feed Transaction / ABA File Hash.
*   **Reporting Effect:** Decreases Cash; Decreases AP Liability.
*   **Close Dependency:** Must be processed before `BANK_READY` and `AP_READY`.

---

## 5. Event: `CustomerDepositReceived` (Pre-Sales Workflow)
*Handling upfront payments for a Job/Project before services are rendered (Unearned Revenue).*

*   **Source Object:** `Quote` / `CustomerDeposit`
*   **Subledger:** Accounts Receivable (AR) / Revenue
*   **Debit:** Bank Account (Asset)
*   **Credit:** Customer Deposits / Unearned Revenue (Liability)
*   **Tax:** GST is generally withheld on deposits (varies by local tax rule engine).
*   **Dimensions:** `Customer` (Header), `Project` (Line level - assigning the deposit to a specific future job).
*   **Economic Date:** Date cash received.
*   **Accounting Date:** Date cash received.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `Unearned_Revenue_Deposit_v1`
*   **Approval:** Automated via Payment Gateway (Stripe) webhook.
*   **Reconciliation:** Tied to the specific Project balance.
*   **Reversal/Correction:** `DepositRefunded` (Cr Bank, Dr Liability).
*   **Evidence:** Payment Gateway Transaction ID / Accepted Quote Hash.
*   **Reporting Effect:** Increases Cash; Increases Liabilities (No impact on PnL yet).
*   **Close Dependency:** Processed before `BANK_READY` and `REVENUE_READY`.

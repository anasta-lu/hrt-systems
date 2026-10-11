# Phase 3B: Accounting Event Matrix (Part 6: Leases, Advanced Inventory & Project Capitalization)

This matrix maps the final batch of 5 core events to reach the 30-event milestone for the HRT Systems V1 accounting kernel. It focuses on advanced IFRS/AASB standards (Lease Accounting), Project-to-Asset transitions, and Inventory COGS.

---

## 26. Event: `InventoryIssued` (COGS Recognition)
*The event where physical inventory is shipped to a customer, officially moving the value from the Balance Sheet to the PnL as Cost of Goods Sold (COGS).*

*   **Source Object:** `FulfillmentRecord` / `Shipment`
*   **Subledger:** Inventory
*   **Debit:** Cost of Goods Sold (Expense)
*   **Credit:** Inventory Asset (Balance Sheet)
*   **Tax:** N/A (Sales tax is handled on the Customer Invoice).
*   **Dimensions:** `Location` / `Warehouse`, `Project`, `Item_Category`.
*   **Economic Date:** The date the goods leave the warehouse.
*   **Accounting Date:** The date of shipment (or delivery, depending on FOB terms).
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `Inventory_COGS_Matching_v1` (Calculated using FIFO or Weighted Average cost logic).
*   **Approval:** Triggered when the warehouse worker marks the order as "Shipped."
*   **Reconciliation:** Aligns the reduction in physical stock with the financial expense.
*   **Reversal/Correction:** `InventoryReturned` (Customer Return).
*   **Evidence:** Signed Bill of Lading / Digital Shipping Manifest.
*   **Reporting Effect:** Decreases Profit (via COGS); Decreases Total Assets (Inventory).
*   **Close Dependency:** Must be processed before `INVENTORY_READY`.

---

## 27. Event: `ProjectWIPCapitalised`
*When a massive internal project (e.g., building a new office or software platform) is completed, and all the accumulated costs are bundled together and converted into a Fixed Asset.*

*   **Source Object:** `ProjectClosure` / `CapitalisationJournal`
*   **Subledger:** Projects / Fixed Assets
*   **Debit:** Property, Plant, & Equipment (Fixed Asset)
*   **Credit:** Capital Work-In-Progress (WIP - Asset Clearing)
*   **Tax:** N/A
*   **Dimensions:** `Project`, `Location`, `Asset_Class`.
*   **Economic Date:** The date the project was officially "Placed in Service."
*   **Accounting Date:** The date of capitalisation approval.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `WIP_to_FixedAsset_Transfer_v1`
*   **Approval:** Project Manager signs off on completion; Financial Controller approves the capitalization.
*   **Reconciliation:** The Project Subledger WIP balance is zeroed out; the FA Subledger gains a new asset equal to the total project cost.
*   **Reversal/Correction:** `AssetCapitalisationReversed`.
*   **Evidence:** Project Completion Certificate.
*   **Reporting Effect:** Shifts the balance from a short-term clearing asset (WIP) to a depreciable long-term asset (PPE).
*   **Close Dependency:** Must be processed before `PROJECTS_READY` and `FA_READY`.

---

## 28. Event: `LeaseLiabilityRecognised` (AASB 16 / IFRS 16)
*When a business signs a long-term lease (e.g., for an office building). Under modern accounting standards, this must be recognized on the balance sheet as an asset and a liability.*

*   **Source Object:** `LeaseContract`
*   **Subledger:** Leases (or Fixed Assets)
*   **Debit:** Right-of-Use (ROU) Asset
*   **Credit:** Lease Liability
*   **Tax:** N/A
*   **Dimensions:** `Location`, `Department`.
*   **Economic Date:** Lease Commencement Date.
*   **Accounting Date:** Lease Commencement Date.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `AASB16_Lease_Capitalisation_v1` (Calculated using the Present Value of future lease payments).
*   **Approval:** CFO/Controller approval of the lease parameters (Discount Rate, Term).
*   **Reconciliation:** Over time, automated events will burn down the ROU Asset (via amortization) and the Lease Liability (via cash payments).
*   **Reversal/Correction:** `LeaseTerminated` or `LeaseModified`.
*   **Evidence:** Signed Commercial Lease Agreement.
*   **Reporting Effect:** Massively inflates both Assets and Liabilities (ensuring the company's true debt is visible to investors).
*   **Close Dependency:** Must be processed before `FA_READY`.

---

## 29. Event: `CustomerRefundIssued`
*The event where actual cash is returned to a customer due to an overpayment or a returned product.*

*   **Source Object:** `CustomerRefund`
*   **Subledger:** Banking / Accounts Receivable (AR)
*   **Debit:** Accounts Receivable (Asset - Re-establishing the balance or clearing an overpayment)
*   **Credit:** Bank Account (Asset)
*   **Tax:** N/A
*   **Dimensions:** `Customer`.
*   **Economic Date:** Date the cash was transmitted.
*   **Accounting Date:** Date the cash clears the bank.
*   **Period:** Derived from Accounting Date.
*   **Accounting Rule:** `AR_Refund_Settlement_v1`
*   **Approval:** Requires Manager approval to release funds.
*   **Reconciliation:** Bank feed transaction matches the system-generated refund.
*   **Reversal/Correction:** `RefundVoided` (if the bank rejects the outgoing payment).
*   **Evidence:** Bank Feed Transaction / Payment Gateway Receipt.
*   **Reporting Effect:** Decreases Cash; Increases AR (or clears a negative AR balance).
*   **Close Dependency:** Must be processed before `BANK_READY` and `AR_READY`.

---

## 30. Event: `DepreciationRecalculated` (Change in Useful Life)
*When an asset's expected lifespan changes (e.g., a machine is breaking down faster than expected), requiring a massive prospective change to all future depreciation expenses.*

*   **Source Object:** `AssetModification`
*   **Subledger:** Fixed Assets (FA)
*   **Debit/Credit:** N/A immediately. (This is a *Configuration/Control Event* that alters the future trajectory of the asset).
*   **Tax:** Alters the Deferred Tax trajectory.
*   **Dimensions:** `Asset_Class`.
*   **Economic Date:** The date the new useful life assessment was made.
*   **Accounting Date:** The start of the current open period.
*   **Period:** The current open period.
*   **Accounting Rule:** `AASB116_Useful_Life_Adjustment_v1`
*   **Approval:** Requires Financial Controller override.
*   **Reconciliation:** The Fixed Asset subledger regenerates the remaining depreciation schedule based on the new Net Book Value and the remaining lifespan.
*   **Reversal/Correction:** `AssetModificationReversed`.
*   **Evidence:** Engineering/Valuation Assessment Report.
*   **Reporting Effect:** No immediate GL impact on the day of change, but heavily alters the Depreciation Expense on the *next* month-end run.
*   **Close Dependency:** Must be processed before `FA_READY`.

# SDLC 25: Inventory, Fixed Assets, Leases & Project Accounting Subledgers

## 1. Executive Summary & Purpose
This document establishes the operational rules, technical data contracts, and statutory accounting standards for:
* **Perpetual Inventory Subledger (Domain 10 - AASB 102)**
* **Fixed Assets & Dual-Book Depreciation (Domain 11 - AASB 116)**
* **Lease Accounting & ROU Amortisation (Domain 11 - AASB 16)**
* **Projects, Timesheets & Contract WIP (Domain 12 - AASB 15)**
* **External Payroll Ingestion & Clearing (Domain 14)**

---

## 2. Perpetual Inventory & Valuation Layers (AASB 102)

### 2.1. Physical Quantities vs. Valuation Layers
In HRT Systems, physical quantity management is strictly decoupled from financial valuation:
* **`inventory_movements`:** Immutable, tamper-proof log recording every physical change in inventory (Receipts, Issues, Warehouse Transfers, Scraps, Stocktake Variances).
* **`inventory_cost_layers`:** Financial tracking layers recording the remaining quantity and historical unit cost under **FIFO** or **Specific Identification**.

### 2.2. Cost Layer Depletion Example (FIFO)
When a delivery note or sales invoice issues 15 units of SKU-A:
1. System queries active cost layers:
   - Layer 1 (Date: Oct 01): 10 units @ \$10.00 each
   - Layer 2 (Date: Oct 05): 10 units @ \$12.00 each
2. Depletion Algorithm:
   - Depletes Layer 1 completely: 10 units $\times$ \$10.00 = \$100.00 (marked `is_depleted = true`)
   - Depletes Layer 2 partially: 5 units $\times$ \$12.00 = \$60.00 (remaining: 5 units)
3. Financial Entry emitted by Kernel:
   $$\text{Debit: 5000 Cost of Goods Sold (COGS) } \$160.00$$
   $$\text{Credit: 1400 Inventory on Hand } \$160.00$$

### 2.3. Net Realisable Value (AASB 102.34) vs Permanent Shrinkage
* **Permanent Shrinkage / Theft / Damage:**
  Physical count reveals 95 units instead of 100. Emits `InventoryCountAdjusted` event:
  $$\text{Debit: 6410 Inventory Shrinkage Expense } \$50.00$$
  $$\text{Credit: 1400 Inventory on Hand } \$50.00$$
* **Net Realisable Value (NRV) Allowance:**
  Market value falls below cost basis. AASB 102 requires writing down to NRV without destroying original cost layers:
  $$\text{Debit: 6420 Loss on Inventory Write-Down (P&L)}$$
  $$\text{Credit: 1409 Allowance for Inventory NRV (Contra-Asset)}$$
  *If market prices subsequently recover, AASB 102.34 allows reversing the allowance up to original cost.*

---

## 3. Fixed Assets & Dual-Book Depreciation (AASB 116)

### 3.1. Dual-Book Architecture
Large mid-market and enterprise businesses maintain two distinct financial records for every capital asset:
1. **AASB Statutory Book:** Governed by AASB 116. Uses useful life estimates, salvage values, and componentization. Reflects true economic wear.
2. **Tax Depreciation Book:** Governed by statutory tax legislation (e.g. Australian ATO Division 40 capital allowance rules, accelerated depreciation, or instant asset write-off thresholds).

Both books run concurrently from a single `fixed_assets` record, posting to separate parallel ledgers (`PRIMARY` vs `TAX`).

### 3.2. Capital Work in Progress (Account 1500)
When constructing complex assets (e.g. a manufacturing facility or custom plant):
1. Project costs, contractor invoices, and raw materials post to:
   $$\text{Debit: 1500 Capital Work in Progress (CWIP - AASB 116)}$$
2. Upon commissioning and placement into service (`AssetPlacedInService` event):
   $$\text{Debit: 1510 Property, Plant & Equipment (Asset Capitalised)}$$
   $$\text{Credit: 1500 Capital Work in Progress (CWIP)}$$
3. Depreciation begins strictly on the **`in_service_date`**, not the acquisition or invoice date.

---

## 4. Lease Accounting & ROU Amortisation (AASB 16)

Under AASB 16 / IFRS 16, operating leases are eliminated from the balance sheet. All material leases (>12 months, non-low value) are recognized as assets and liabilities.

### 4.1. Initial Measurement (Commencement Date)
At commencement date, the present value of future lease payments is calculated using the tenant's Incremental Borrowing Rate (IBR):
$$\text{Debit: 1600 Right-of-Use (ROU) Asset (Property / Equipment)}$$
$$\text{Credit: 2600 Lease Liability (Present Value of Lease Payments)}$$

### 4.2. Periodic Lease Schedule
Every periodic payment decomposes into three distinct financial components:
1. **Interest Unwinding (Finance Cost):**
   $$\text{Interest Amount} = \text{Opening Lease Liability} \times \text{Discount Rate}$$
2. **Principal Reduction:**
   $$\text{Principal Amount} = \text{Cash Payment} - \text{Interest Amount}$$
3. **ROU Asset Amortisation:**
   $$\text{Depreciation} = \frac{\text{Initial ROU Asset Value}}{\text{Lease Term (Months)}}$$

**Ledger Postings per Month:**
$$\text{Debit: 2600 Lease Liability (Principal Reduction)}$$
$$\text{Debit: 6800 Lease Interest Expense (Finance Cost)}$$
$$\text{Credit: 1020 Payment Clearing / Cash}$$
*Plus ROU Depreciation:*
$$\text{Debit: 6310 ROU Asset Amortisation Expense}$$
$$\text{Credit: 1609 Accumulated Amortisation (ROU Asset)}$$

---

## 5. Projects, Timesheets & Contract WIP (AASB 15)

### 5.1. Strict Separation: Capital WIP vs Contract WIP
* **Capital WIP (Account 1500 - AASB 116):** Internal asset creation. Capitalises into balance sheet PPE.
* **Contract WIP / Contract Asset (Account 1400 - AASB 15):** Work performed for external customers. Unbilled project costs and earned performance. Clears to Cost of Goods Sold or Billed Accounts Receivable upon invoicing.

### 5.2. Time & Materials vs Fixed-Fee Progress Claims
1. **Time & Materials:**
   - Hours logged via `timesheets` $\to$ Approved $\to$ Generate `project_wip_entries`.
   - On billing run: Invoices issued $\to$ Clears WIP $\to$ Debits AR, Credits Revenue.
2. **Fixed-Fee Milestone / Progress Claims:**
   - Project costs accumulate in operational project ledgers.
   - Revenue recognized according to percentage of completion (Input or Output method).

---

## 6. External Payroll Ingestion & Clearing (Domain 14)

### 6.1. PII Boundary & Compliance
To maintain zero GDPR/Privacy Act risk in the core ERP, detailed employee personnel records (TFN, super fund membership numbers, medical leave details) remain in specialized payroll software (Employment Hero, KeyPay, Xero Payroll).

HRT Systems ingests summarized, authenticated **Payroll Run Batches**:
* Entity ID
* Pay Period Dates
* Payment Execution Date
* Gross Wages
* Net Wages Payable
* PAYG Withholding Tax
* Superannuation Guarantee (SG) Cost

### 6.2. Statutory Superannuation Guarantee (SG) Invariant
In Australian accounting, Superannuation is an employer cost **over and above** gross salary. It cannot be deducted from gross pay.

**Financial Posting Emitted by Kernel (`PayrollResultAccounted` Event):**
$$\text{Debit: 6100 Wages & Salaries Expense } \$100,000.00$$
$$\text{Debit: 6150 Superannuation Guarantee Expense (11.5\%) } \$11,500.00$$
$$\text{Credit: 2110 Net Wages Payable Clearing } \$68,000.00$$
$$\text{Credit: 2120 PAYG Withholding Tax Payable (ATO) } \$32,000.00$$
$$\text{Credit: 2130 Superannuation Clearing Account } \$11,500.00$$

When the ABA file releases funds on payday:
$$\text{Debit: 2110 Net Wages Payable Clearing } \$68,000.00$$
$$\text{Credit: 1020 Payment Clearing Account } \$68,000.00$$

# SDLC Phase 5: Payroll & HRIS Integration Module

## 1. Payroll Strategy: The Tri-Modal Approach
To accommodate businesses at different stages of growth and technical maturity, the system handles payroll through three distinct options. The architecture ensures these options are completely modular and can be swapped as the business scales.

### Option 1: The Manual Payroll Journal (Lowest Tier / Simplest)
For businesses that run payroll through a disconnected accountant or legacy system, the ERP provides a highly configured, intelligent manual journal template.
- The user enters the gross amounts, and the system instantly maps the lines to the correct GL accounts based on onboarding configurations.
- **Example Template Post:**
  - **Debit:** Wages and Salaries Expense (Gross Pay) - $10,000
  - **Credit:** PAYG / Tax Withholdings Payable (Liability) - $1,500
  - **Credit:** Deductions / Superannuation Payable (Liability) - $500
  - **Credit:** Wages / Bank Clearing Payable (Net Pay) - $8,000

### Option 2: "Best of Breed" External Integrations (Current Focus)
The system acts as the financial aggregator, pulling detailed data from industry-leading Payroll/HRIS platforms (e.g., Employment Hero, ADP, Xero Payroll).
- **Deep Dimensional Splitting (Pro Tier):** The integration pulls detailed timesheets and dynamically splits the *Wages and Salaries Expense* across multiple dimensions (e.g., allocating a percentage of a wage to specific Projects or Departments based on time tracked).

### Option 3: Future Native Payroll Module
The architectural foundation leaves room for a proprietary Native Payroll engine to be developed in later phases.
- Because the core system is modular, if a business upgrades from an external integration (Option 2) to the Native Payroll module (Option 3), the underlying General Ledger mappings and Dimensional splitting logic remain exactly the same.

## 3. Integration Architecture (Temporal.io)
Because payroll contains highly sensitive employee data and requires perfect accuracy, the synchronization is orchestrated by Temporal.
- **Security:** Payroll payloads often contain Personally Identifiable Information (PII). Our Adapter Pattern ensures that we only extract the *financial and dimensional* data (amounts, tax totals, project codes) and immediately discard the PII before writing to the PostgreSQL Ledger.
- **Resiliency:** If Employment Hero's API is down during a scheduled sync, Temporal will automatically back off and retry until the payroll journal is successfully posted.

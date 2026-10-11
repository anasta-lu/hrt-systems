# Phase 9: Reporting, Analytics & Semantic Model

This phase outlines how data is extracted from the HRT Systems accounting kernel and presented to users and AI. The core mandate from the Master Context is: *"Do not query raw operational tables ad hoc for reporting."*

## 1. The Data Pipeline (CQRS Principle)
To ensure the transactional database remains lightning-fast for day-to-day operations, reporting utilizes a Command Query Responsibility Segregation (CQRS) inspired pipeline.

`Operational DB → Accounting Data Model → Semantic Model → Canonical Metrics → Reports/Dashboards/AI`

*   **Accounting Data Model:** Materialized views and indexed roll-ups (e.g., aggregating millions of `ledger_entries` into monthly GL account balances by dimension).
*   **The Semantic Model:** A business-friendly metadata layer. Instead of exposing "Account 4000", the semantic model defines the concept of "Gross Revenue." 
*   **Canonical Metrics:** Standardized, immutable definitions for key business drivers: *EBITDA, Net Revenue, AR Aging, Free Cash Flow, Working Capital, and Project WIP.*

## 2. Reproducibility & Report Versioning
Because financial audits require exact historical accuracy, reports in HRT Systems are reproducible.
*   If a CFO runs a Q3 Board Report on October 5th, and runs the exact same report on December 15th, the numbers must match exactly (unless an explicit `AccountingPeriodReopened` event occurred). 
*   The system achieves this by querying the `ledger_entries` against the specific `accounting_date` and `accounting_rule_version`, ignoring any retrospective dimensional changes made after the period closed.

## 3. Dimensional Drill-Down
Users can click on high-level Canonical Metrics (e.g., Total Marketing Expense) and seamlessly drill down through the Semantic Model.
*   *Drill Path:* `P&L Line` → `GL Account` → `Dimension (e.g., Project A)` → `Ledger Entry` → `Accounting Event` → `Source Business Event` → `AP Bill PDF Evidence`.

## 4. Security & Data Scopes in Reporting
The Semantic Model strictly enforces the Data Scopes defined in Phase 6. If a Regional Manager runs a company-wide P&L report, the Semantic Model intercepts the query and automatically filters out any ledger entries that do not carry their specific `Region` dimension, ensuring they only see their own profitability.

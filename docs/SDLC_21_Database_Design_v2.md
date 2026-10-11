# SDLC 21: Database Design v2 (Verified Schema)

## Overview
This document outlines the verified Database v2 schema architecture for HRT Systems. The schema has been successfully tested and proved robust against violations of accounting principles through rigorous PostgreSQL triggers.

## Key Architectural Decisions

1. **Tenancy Model**
   - **Schema-per-tenant** is the standard architecture.
   - **Database-per-tenant** is available as a paid enterprise option.
   - The Control Plane runs migrations across all schemas to ensure zero version drift.

2. **Parallel Ledgers (Multi-Book)**
   - Implemented at the `accounting_events` and `ledger_entries` level.
   - A single `business_event` (e.g., an invoice) can spawn multiple `accounting_events` across different ledgers (e.g., AASB, Tax, Group IFRS).
   - This prevents duplicating the source transactions while allowing different accounting rules.

3. **Multi-Currency & Consolidation**
   - **Transaction Currency:** The original currency of the document.
   - **Base Currency:** The local currency of the entity.
   - **Reporting Currency:** The group-wide consolidation currency (stored on `tenant_settings`).
   - Every `ledger_entry` records the amount in **all three currencies**. This eliminates the need to recalculate historical FX rates during month-end consolidations for P&L accounts.

4. **Dynamic Dimensions**
   - We use a `dimension_sets` pattern (hash-based UUIDs) for the Trial Balance (`v_trial_balance`).
   - This provides the flexibility of tags without the indexing penalty of JSONB columns on the main ledger tables, keeping reporting blazing fast.

## Security & Immutability Triggers
The schema relies heavily on database-level triggers to enforce the strict accounting kernel principles. These were verified in the test container:
- `HRT-BAL-XXX`: Enforces that Debits = Credits exactly. The constraint is DEFERRABLE and checks at the end of the transaction.
- `HRT-IMMUTABLE`: Prevents `UPDATE` or `DELETE` on any financial history (`ledger_entries`). Financial history can only be corrected with reversing entries.
- `HRT-PERIOD-XXX`: Enforces that ledger entries can only be posted into `OPEN` or `REOPENED` accounting periods.

## Schema Location
The definitive V2 schema is located at `sql/001_tenant_schema_v2.sql` and the test verification script is at `sql/verify_schema_v2.sql`.

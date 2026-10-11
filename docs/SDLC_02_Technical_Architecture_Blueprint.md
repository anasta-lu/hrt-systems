# SDLC Phase 2: Technical Architecture Blueprint (Master)

## 1. Core Technology Stack
- **Backend Framework:** Python + FastAPI (Async-native, high performance, excellent for API integration workloads).
- **Database:** PostgreSQL (Strict ACID compliance, JSONB for dynamic fields, advanced schema/RLS capabilities).
- **Workflow & Integration Engine:** Temporal.io (Handles distributed state, retries, and long-running syncs with external systems like Monday/Asana).

## 2. Database Architecture: Hybrid Multi-Tenancy
The database is architected to support both rapid scaling for startups and strict physical isolation for enterprise groups, using a dual-tier approach:

### 2.1. Standard Tier (Shared Schema + RLS)
- All Standard tier customers share a single `public` schema in PostgreSQL.
- **Security:** Strict Row-Level Security (RLS) policies are enforced at the database engine level, ensuring a query can only ever return rows where `tenant_id` matches the authenticated user's session.

### 2.2. Pro Tier (Dedicated Schema-per-Tenant)
- Customers can choose to initialize on the Pro Tier from day one during onboarding, or upgrade to it later.
- **Initialization & Upgrades:** If chosen at signup, a dedicated schema (e.g., `schema_tenant_123`) is provisioned immediately. If a Standard customer chooses to upgrade later, a one-way, automated background job seamlessly migrates them to a dedicated schema without downtime (downgrades are not permitted).
- **Benefits:** Absolute physical data isolation, dedicated backup/restore capabilities, and localized compliance (e.g., storing a specific schema in a geographically localized AWS region).

## 3. General Ledger & Multi-Currency Architecture
To comply strictly with AASB 121 / IAS 21, the core ledger does not rely on post-calculation for foreign currency.

- **Row-Level Precision (Option A):** Every single journal line contains four critical columns:
  1. `foreign_amount` (e.g., $100.00)
  2. `foreign_currency_code` (e.g., 'USD')
  3. `base_amount` (e.g., $150.00 AUD)
  4. `exchange_rate` (e.g., 1.50)
- **Automated FX Engine:** Temporal.io background workers run end-of-month revaluations, analyzing unsettled foreign AP/AR lines and automatically generating Unrealized FX Gain/Loss journal entries.

## 4. The "Hub and Spoke" Integration Ingestion API
Because the ERP acts as a hub for external operational tools, the ingestion perimeter is designed for extreme fault tolerance.

1. **Receive:** FastAPI receives an external webhook (e.g., Asana task complete).
2. **Accept:** FastAPI instantly drops the raw JSON payload into a highly available queue and returns `202 Accepted` to the external system (preventing timeouts).
3. **Process:** Temporal.io picks up the payload, translates it into a Standard Operational Event, maps it to the Dimensional CoA, and writes the financial impact to the PostgreSQL ledger. If the database is locked, Temporal automatically applies exponential backoff and retries safely.

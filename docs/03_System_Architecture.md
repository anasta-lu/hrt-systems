# System Architecture

To build a SaaS ERP capable of scaling globally and servicing multiple industries, the architecture must balance early-stage velocity with long-term scalability.

## 1. High-Level Architectural Pattern
**Recommendation:** Modular Monolith (Transitioning to Microservices).
- **Why:** Starting with microservices adds too much operational overhead for a new system. A modular monolith enforces logical boundaries (Bounded Contexts) inside a single deployable unit. If a module (e.g., Reporting) requires massive compute, it can be extracted later.

## 2. Technology Stack Recommendations
*(These are recommendations and can be swapped based on team expertise)*
- **Backend API:** Node.js (TypeScript/NestJS), Go, or C# (.NET Core). Strongly typed languages are heavily recommended for financial software to prevent runtime mathematical/type errors.
- **Frontend:** React or Vue.js (Single Page Application) with a robust state management library.
- **Database (OLTP):** PostgreSQL. Unrivaled for relational integrity, ACID compliance, and JSONB support for extensible attributes.
- **Message Broker:** RabbitMQ or Apache Kafka (for asynchronous event-driven communication between bounded contexts).
- **Caching:** Redis (for session management, API rate limiting, and caching static lookups like Tax Rates).

## 3. Data Architecture & Multi-Tenancy
Given that this is a B2B SaaS system, you must support thousands of separate businesses (tenants).

**Multi-Tenancy Strategy: Row-Level Security vs Schema per Tenant**
- **Option A (Shared Database, Shared Schema):** Every table has a `tenant_id`. Fastest to scale, easiest to migrate. High risk of data leakage if queries forget `WHERE tenant_id = X`. Can be mitigated with PostgreSQL Row-Level Security (RLS). **(Recommended for startup velocity)**.
- **Option B (Shared Database, Separate Schema):** Every tenant gets their own schema (e.g., `tenant_123.invoices`). Better isolation, but running database migrations across 10,000 schemas is complex.
- **Option C (Separate Database per Tenant):** Used for Enterprise clients needing absolute data isolation.

## 4. Event Sourcing for Financial Records
For the Core Ledger, consider **Event Sourcing**. Instead of storing just the *current state* of an account balance, store every *event* that changes the balance.
- **Why:** Absolute auditability. If an auditor asks "how did this balance get to $10,000 on Tuesday?", you can replay the events.
- **Implementation:** The `Journal` and `JournalLine` tables effectively act as an event store. Balances are calculated by aggregating these lines, typically materialized into a read-model (e.g., `AccountBalance` table) for fast querying.

## 5. Security & Compliance
- **Authentication:** OAuth 2.0 / OpenID Connect (e.g., Auth0, AWS Cognito).
- **Role-Based Access Control (RBAC):** Crucial for ERPs. A user might be an "Admin" for one tenant but a "Read-Only Viewer" for another.
- **Audit Logs:** Every destructive or modifying action (Update/Delete) across the system must be logged with User ID, Timestamp, and Before/After payloads.

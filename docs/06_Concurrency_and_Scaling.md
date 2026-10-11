# Concurrency, Scaling & Reporting (CQRS)

Handling financial data requires absolute precision. Scaling an ERP introduces challenges around race conditions and reporting performance.

## 1. Handling Concurrency and Race Conditions
When multiple users (or automated bank feeds) attempt to modify the same account balance simultaneously, you must prevent data corruption.

### Optimistic vs. Pessimistic Locking
- **Pessimistic Locking (`SELECT ... FOR UPDATE`):** Locks the database row so no one else can read/write it until the transaction completes. Highly secure but can cause severe bottlenecks and deadlocks in a high-volume system.
- **Optimistic Locking (Recommended):** Every record has a `version_number`. 
  1. User A and User B both read Invoice #100 (version 1).
  2. User A updates the invoice. The system saves it, making it version 2.
  3. User B tries to update the invoice, sending `version: 1` in their payload.
  4. The database rejects User B's update because the current version is 2. User B must refresh and try again.

## 2. Transaction Isolation Levels
PostgreSQL defaults to `Read Committed`. For core financial ledger entries, you may need to escalate the transaction isolation level to `Serializable` or `Repeatable Read` to prevent phantom reads during complex reporting or month-end close procedures.

## 3. CQRS (Command Query Responsibility Segregation)
As an ERP grows, you will realize that **writing data** (posting journals) and **reading data** (generating a 12-month P&L report) have entirely different scaling profiles.

**The Problem:** Running a heavy Profit & Loss query on your primary transactional database will slow down the system for users trying to create invoices.

**The Solution (CQRS):**
Separate the "Write Model" from the "Read Model."
1. **Commands (Writes):** Users create invoices and post journals. These hit the primary Relational Database (PostgreSQL) optimized for ACID transactions.
2. **Event Publisher:** Upon successful commit, an event (`JournalPosted`) is published to a message broker (Kafka/RabbitMQ).
3. **Queries (Reads):** A separate service listens to these events and updates a secondary database optimized for querying (e.g., Elasticsearch for fast searching, or a separate Postgres/ClickHouse instance pre-aggregated for reports).
4. **Reports:** When a user asks for a Balance Sheet, the API queries the Read Database, returning results instantly without touching the primary Write Database.

## 4. Pre-Aggregated Balances
Calculating an account balance from inception by summing up millions of `journal_lines` is slow.
- **Implementation:** Maintain a `monthly_account_balances` table.
- When generating a report for September 2026, the system takes the pre-calculated closing balance of August 2026, and only sums the journal lines for September. This turns an $O(N)$ operation into an $O(1)$ operation for historical periods.

## 5. Background Jobs & Queues
Never perform heavy tasks synchronously in the HTTP request cycle.
- Examples: Generating PDF invoices, importing CSV bank statements, running depreciation schedules, sending emails.
- Use a robust queueing system (e.g., BullMQ for Node.js, Sidekiq for Ruby, Celery for Python) to offload these tasks to background workers.

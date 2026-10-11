# Database & Multi-Tenancy Deep Dive

When building an ERP serving multiple businesses, data isolation and database schema management are critical. A single misplaced query could expose one company's financial records to another.

## 1. Multi-Tenancy: The PostgreSQL Row-Level Security (RLS) Approach

If you choose the "Shared Database, Shared Schema" model (the fastest way to scale initially), every table MUST have a `tenant_id` column. However, relying on application developers to remember to append `WHERE tenant_id = X` to every single query is a recipe for disaster.

**The Solution: PostgreSQL Row-Level Security (RLS)**

RLS allows you to enforce data access policies at the database engine level, making it physically impossible for the application layer to query another tenant's data, even if it tries.

### Implementation Example:

**Step 1: Create the table and enable RLS**
```sql
CREATE TABLE invoices (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    amount DECIMAL(19,4),
    -- other columns
);

-- Enable RLS on the table
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
```

**Step 2: Define the Policy**
```sql
-- This policy states that users can only interact with rows where the tenant_id 
-- matches a configuration variable we will set per transaction.
CREATE POLICY tenant_isolation_policy ON invoices
    USING (tenant_id = current_setting('app.current_tenant_id')::UUID);
```

**Step 3: Usage in the Application Backend**
When your backend Node/Go/C# app receives a request and checks out a database connection from the pool, it runs this *before* running any business logic:

```sql
-- Set the tenant ID for the duration of this specific transaction
SET LOCAL app.current_tenant_id = 'a1b2c3d4-tenant-uuid-here';
```

Now, even if a developer writes `SELECT * FROM invoices;`, PostgreSQL will silently append the policy and only return that specific tenant's invoices.

## 2. Managing Schema Migrations

As you add features (e.g., Inventory, Payroll), the database schema will evolve. Managing this across a live SaaS platform is challenging.

- **Migration Tooling:** Use a robust migration tool (e.g., Flyway, Liquibase, or ORM-specific tools like Prisma/Knex migrations).
- **Zero-Downtime Migrations:** In an ERP, you cannot afford to take the system offline to add a column.
  - **Rule 1:** Migrations must be backwards compatible.
  - **Rule 2:** Never rename a column or drop a column in a single deployment.
  - **Pattern (Dropping a column):** 
    1. Deploy code that stops writing to `old_column`. 
    2. Wait. 
    3. Run a migration to drop `old_column` weeks later.
- **Data Migrations vs Schema Migrations:** Keep them separate. Modifying millions of journal lines (Data Migration) will lock tables and cause downtime. These should be run as background batch jobs, not during startup schema migrations.

## 3. Handling Money (Precision)
**Never use FLOAT or REAL data types for financial values.** Floating-point arithmetic introduces rounding errors (e.g., `0.1 + 0.2 = 0.30000000000000004`).

- **SQL:** Always use `DECIMAL(19,4)` or `NUMERIC(19,4)`. This allows for values up to 999 trillion, with 4 decimal places of precision (necessary for tax calculations and exchange rates).
- **Application Layer:** Do not use native floating-point numbers in JavaScript/Node.js. Use specialized libraries like `decimal.js`, `currency.js`, or `Dinero.js` to handle all math before writing to the database.
- **Alternative (Integer math):** Store everything in the smallest unit (e.g., Cents for USD). $100.50 is stored as `10050`. This is popular but gets complicated when dealing with multi-currency exchange rates and 4-decimal tax percentages. DECIMAL in Postgres is generally preferred for ERPs.

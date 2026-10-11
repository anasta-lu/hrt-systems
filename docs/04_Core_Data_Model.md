# Core Data Model: The Accounting Engine

The foundation of any ERP/Accounting system is the double-entry accounting data model. If this is designed poorly, the entire application will fail.

Here is a simplified Relational Database schema design for the Core Ledger.

## 1. Chart of Accounts (COA)
The list of all categories to which money can be allocated.

```sql
CREATE TABLE account_types (
    id UUID PRIMARY KEY,
    name VARCHAR(50), -- Asset, Liability, Equity, Revenue, Expense
    normal_balance VARCHAR(6) -- DEBIT or CREDIT
);

CREATE TABLE accounts (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    account_type_id UUID REFERENCES account_types(id),
    code VARCHAR(20), -- e.g., "200"
    name VARCHAR(100), -- e.g., "Sales Revenue"
    description TEXT,
    currency_code VARCHAR(3),
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP,
    UNIQUE(tenant_id, code)
);
```

## 2. Transactions & Journals
A "Transaction" in the business world (like an Invoice) results in a "Journal" in the accounting world.

```sql
CREATE TABLE journals (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    date DATE NOT NULL,
    description VARCHAR(255),
    reference VARCHAR(100), -- E.g., "INV-1042"
    source_entity_type VARCHAR(50), -- "INVOICE", "BILL", "MANUAL"
    source_entity_id UUID,
    created_by UUID,
    created_at TIMESTAMP
);

CREATE TABLE journal_lines (
    id UUID PRIMARY KEY,
    journal_id UUID REFERENCES journals(id),
    tenant_id UUID NOT NULL,
    account_id UUID REFERENCES accounts(id),
    contact_id UUID NULL, -- Optional tracking of WHO the line relates to
    tax_rate_id UUID NULL,
    description VARCHAR(255),
    debit_amount DECIMAL(19,4) DEFAULT 0,
    credit_amount DECIMAL(19,4) DEFAULT 0,
    -- Rule: debit_amount and credit_amount cannot both be > 0
);
```

## 3. Double-Entry Integrity Rules
At the application (and ideally database trigger) level, the system MUST enforce:
1. `SUM(debit_amount) = SUM(credit_amount)` for any given `journal_id`. A journal cannot be posted unless it balances.
2. Immutability: Once a `journal` is posted, it cannot be updated or deleted. To correct an error, a new `journal` must be posted that reverses the original entries (a "Reversing Journal").

## 4. Extensibility via Tags / Dimensions
To support different business specializations (e.g., tracking revenue by "Project", "Department", or "Location") without changing the schema, use tracking categories.

```sql
CREATE TABLE tracking_categories (
    id UUID PRIMARY KEY,
    tenant_id UUID,
    name VARCHAR(50) -- e.g., "Region", "Department"
);

CREATE TABLE tracking_options (
    id UUID PRIMARY KEY,
    category_id UUID REFERENCES tracking_categories(id),
    name VARCHAR(50) -- e.g., "North America", "Sales"
);

CREATE TABLE journal_line_tracking (
    journal_line_id UUID REFERENCES journal_lines(id),
    tracking_option_id UUID REFERENCES tracking_options(id),
    PRIMARY KEY (journal_line_id, tracking_option_id)
);
```
This design allows businesses to slice and dice their Profit & Loss reports by any dimension they need, providing the flexibility needed to scale across industries.

# Dimensional Chart of Accounts (CoA) Architecture

To bridge the gap between small business software (like Xero) and mid-market ERPs (like Sage Intacct or NetSuite), the General Ledger must implement a **Dimensional (or Relational) Chart of Accounts**.

## 1. The Flaw in Flat Chart of Accounts (Xero Approach)
Xero uses a flat CoA (e.g., `4000 - Sales`). To track revenue by department, Xero offers two "Tracking Categories". As businesses scale and need to track by Department, Location, Project, *and* Employee, Xero's architecture hits a hard limit. 
The traditional enterprise workaround (Oracle/NetSuite) is a **Segmented Key** (e.g., `01-4000-100-SYD-999`), which creates thousands of hardcoded combinations and becomes a nightmare to manage.

## 2. The Solution: Dimensional / Relational CoA
We will keep the base account flat and clean (just the natural classification), but force/allow transactions to tag independent relational "Dimensions".

### Database Schema Design

```sql
-- 1. The Core Account (Clean, natural classification)
CREATE TABLE accounts (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    code VARCHAR(20), -- e.g., "4000"
    name VARCHAR(100), -- e.g., "Consulting Revenue"
    account_type VARCHAR(50) -- REVENUE, EXPENSE, ASSET, LIABILITY, EQUITY
);

-- 2. Dimension Definitions (Dynamic metadata for the tenant)
CREATE TABLE dimensions (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    name VARCHAR(50), -- e.g., "Project", "Department", "Location"
    is_mandatory BOOLEAN DEFAULT FALSE
);

-- 3. Dimension Values
CREATE TABLE dimension_values (
    id UUID PRIMARY KEY,
    dimension_id UUID REFERENCES dimensions(id),
    value_code VARCHAR(50), -- e.g., "SYD", "PRJ-101"
    value_name VARCHAR(100) -- e.g., "Sydney Office", "Website Redesign"
);

-- 4. Journal Lines (The Transaction)
CREATE TABLE journal_lines (
    id UUID PRIMARY KEY,
    journal_id UUID REFERENCES journals(id),
    account_id UUID REFERENCES accounts(id),
    debit_amount DECIMAL(19,4) DEFAULT 0,
    credit_amount DECIMAL(19,4) DEFAULT 0
);

-- 5. The Relational Dimensions Join Table
-- This is where the magic happens. A single journal line can be tagged 
-- with infinite dimensions without altering the schema.
CREATE TABLE journal_line_dimensions (
    journal_line_id UUID REFERENCES journal_lines(id),
    dimension_id UUID REFERENCES dimensions(id),
    dimension_value_id UUID REFERENCES dimension_values(id),
    PRIMARY KEY (journal_line_id, dimension_id)
);
```

## 3. Inheritance & Modular Rules
This architecture allows the system to remain highly modular:
- **Professional Services Module:** When installed, this module injects the `Project` and `Employee` dimensions. When a timesheet is billed, the resulting journal entry automatically tags the revenue to those dimensions.
- **Wholesale Module:** When installed later, it injects `Warehouse` and `Product Line` dimensions. The Core GL remains completely untouched.

## 4. User Experience (UX)
While the backend is highly relational and dimensional, the frontend must remain as intuitive as Xero. 
When a user creates a bill, they select the core account (`6000 - Advertising`). Based on tenant settings, the UI dynamically renders dropdowns for active dimensions (e.g., `Department`), allowing seamless data entry.

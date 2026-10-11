# Strategic Roadmap & Go-To-Market

Based on the strategic goal of overtaking Xero while targeting the Australian mid-market, the development and release phases are structured as follows:

## Phase 1: Core Foundation & Professional Services
**Target Audience:** Australian agencies, consultancies, IT firms, and legal setups that have outgrown Xero due to poor project tracking or billing limitations.

### Core Modules:
1. **General Ledger (GL):** 
   - Multi-dimensional Chart of Accounts.
   - Automated tax engine specifically supporting Australian GST/BAS out of the box.
2. **CRM & Quoting:** 
   - Scoping professional service engagements.
3. **Time & Expense Tracking:** 
   - The operational lifeblood of professional services.
4. **Project Management & Billing:** 
   - Support for fixed-fee, time-and-materials, and retainer-based billing.
   - Automatic mapping of invoices back to the GL using the Dimensional CoA (tagging revenue to specific projects/employees).

### The "Trojan Horse" Strategy: Xero API Integrator
**Crucial Requirement:** To lower the barrier to entry, the system must include a flawless 2-way Xero API integration.
- **Why:** Startups and mid-market firms will want to keep Xero initially so their external accountants can file taxes without learning a new system. 
- **How it works:** Users utilize our system for operational workflows (Time tracking, complex Project Billing, CRM). Our system acts as the operational master, syncing summarized journal entries or invoices down to Xero.
- **The Endgame:** Once the business and their accountant trust our GL and reporting, they "flip the switch" to turn off Xero and rely entirely on our platform.

---

## Phase 2: Commercial & Wholesale (Future Scale)
Because the foundation is built on dynamic Bounded Contexts and a Dimensional CoA, pivoting to a new industry does not require rewriting the core ledger.

### Core Modules:
1. **Inventory & Order Management:**
   - Real-time stock tracking.
   - Multi-warehouse support.
2. **Dimensional Adaptation:**
   - The dimensional CoA instantly adapts to track Cost of Goods Sold (COGS) and Revenue by `Warehouse` or `SKU Category`.

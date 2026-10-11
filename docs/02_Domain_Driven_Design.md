# Domain-Driven Design (DDD): Bounded Contexts

To ensure the ERP system can scale and remain maintainable as teams grow, the system should be designed using Domain-Driven Design principles. By separating the system into "Bounded Contexts," we ensure that changes in one module (like Inventory) do not break the Core Ledger.

## 1. Core Ledger Context (The Source of Truth)
This is the heart of the application. It knows nothing about invoices, products, or employees. It only knows about debits, credits, and accounts.
- **Entities:** Account, Journal, JournalLine, AccountingPeriod.
- **Rules:** Debits must always equal Credits. Journals are immutable once posted.

## 2. Invoicing & Billing Context (AR/AP)
Handles the lifecycle of money owed to the business (AR) and money the business owes (AP).
- **Entities:** Invoice, Bill, CreditNote, Payment.
- **Interaction:** When an Invoice is "Approved," this context emits a `SalesInvoiceApproved` event. The Core Ledger context listens to this event and creates the corresponding Journal Entries (Debit Accounts Receivable, Credit Sales Revenue).

## 3. Contact Management Context
Manages all external parties the business interacts with.
- **Entities:** Customer, Supplier, ContactPerson, Address.
- **Interaction:** Used by the Invoicing context to assign invoices to specific customers.

## 4. Banking & Reconciliation Context
Handles the flow of actual cash and matching it against expected cash (AR/AP).
- **Entities:** BankAccount, BankTransaction, BankRule, Reconciliation.
- **Interaction:** Pulls data from external bank feeds. Allows users to match a BankTransaction to an Invoice/Payment. 

## 5. Inventory & Products Context (Extension)
Handles the physical goods.
- **Entities:** Item, Warehouse, StockMovement, BillOfMaterials.
- **Interaction:** When goods are sold on an invoice, this context emits a `StockDepleted` event, triggering Cost of Goods Sold (COGS) journals in the Core Ledger.

## 6. Taxation Context
Calculates and tracks tax liabilities across jurisdictions.
- **Entities:** TaxRate, TaxComponent, TaxReturn.
- **Interaction:** Evaluates line items on Invoices and Bills to compute necessary tax amounts and posts to Tax Liability accounts.

## Architecture Implication
By strictly adhering to Bounded Contexts, you can start with a **Modular Monolith** (all contexts in one codebase/repository but strictly separated by namespaces/packages). As the application scales, you can extract a context (e.g., Invoicing) into its own standalone **Microservice** without having to untangle spaghetti code.

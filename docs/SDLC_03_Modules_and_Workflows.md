# SDLC Phase 3: Modules & Operational Workflows Blueprint

## 1. Chart of Accounts (CoA) Best Practices
Adhering to enterprise best practices (e.g., Rand Group guidelines), the system enforces a strict, scalable accounting structure:
- **Thin Natural Accounts:** The core account strictly defines the "What" (e.g., `4000 - Sales Revenue`). Numbering conventions follow standard GAAP blocks (1xxx Assets, 2xxx Liabilities, etc.) with numeric gaps to allow for future scalability.
- **No Embedded Logic:** Users cannot create accounts like `4000-Sales-Sydney`. All "Who, Where, and Why" data is strictly managed via the Dimensional tagging engine.

## 2. Tiered Architecture & Onboarding
- **Tier Structure:** Sole Trader/ABN -> Startup/Small -> Pro. System complexity (like multi-entity consolidations or advanced IFRS rules) is dynamically hidden or exposed based on the tier.
- **Assisted Implementation:** Onboarding is not fully self-serve. It is a paid, highly-structured configuration process guided by professional staff and AI documentation to ensure the baseline accounting setup is flawless.
- **The "Low Lock-In" Guarantee:** To incentivize signups and reduce risk for startups, the system features a robust, one-click data export tool specifically formatted for Xero/QuickBooks, giving customers peace of mind that they can easily leave if needed.

## 3. Pre-Sales to Billing Workflow (Quote to Cash)
The system acts as an operational powerhouse, seamlessly moving a customer from a prospect to a paid invoice.

### 3.1. Proposals & Quoting
- **Rich Media Builder:** Proposals can include rich text, attachments, photos of the site/project, and detailed scopes of work.
- **Upfront Payments & Discounts:** Proposals can be configured to request upfront payments (deposits), either in part or in full. The system natively handles logic to offer percentage or fixed discounts for early or in-full upfront payments.

### 3.2. Job Conversion & Revenue Recognition
- **Auto-Conversion:** When a client accepts a quote and pays the upfront deposit, the system automatically spins up a `Job` (which acts as a tracking Dimension).
- **Accounting Treatment:** The upfront payment is automatically journaled to a Liability account (e.g., *Customer Deposits / Unearned Revenue*). As milestones are hit and invoices are generated, the system automatically moves this liability into Realized Revenue.

### 3.3. Advanced Invoicing & AR
- **Invoice Engine:** Highly customizable invoice templates supporting balance forwarding (showing previous unpaid invoices) and integrated payment gateways (Stripe, GoCardless).
- **Debt Collection:** Automated, scheduled email and SMS reminders for overdue accounts, tied to a real-time Accounts Receivable Aging dashboard.

## 4. Advanced Accounting & Month-End Controls
- **Automated RevRec & Accruals:** For medium/Pro businesses, the system can automatically amortize prepaid expenses or defer revenue over the life of a contract (e.g., recognizing a $12,000 annual contract as $1,000/month).
- **The "Spreadsheet" Fallback:** For users who find full automation intimidating, the system provides an embedded, spreadsheet-like grid view. This allows users to easily manually calculate and post their end-of-month accruals and provisions while remaining securely inside the software.

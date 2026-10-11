# SDLC Phase 1: Planning & Requirements Analysis (Master Blueprint)

## 1. Executive Vision
To build a true, Enterprise-Grade Financial Management System and ERP that caters to businesses ranging from ambitious startups to medium-sized groups. Unlike monolithic legacy ERPs or entry-level tools (like Xero), this platform is rooted in strict AASB/IFRS/GAAP standards while maintaining an intuitive, template-driven onboarding experience. 

The system operates on a dual philosophy: it provides highly configurable native modules for workflows and approvals, while simultaneously acting as the ultimate "Financial Hub" that integrates natively with Best-of-Breed operational tools (Monday, Asana, ServiceM8).

## 2. Target Market & Go-To-Market Strategy
- **Primary Segments:** Professional & B2B Services (Agencies, IT Consultancies) and Construction/Trades.
- **Why:** These segments sell time and expertise. They quickly outgrow basic accounting software due to poor project tracking, limited dimensional reporting, and a lack of multi-entity consolidation capabilities.

## 3. Core Accounting Architecture & Compliance

### 3.1. Dimensional General Ledger
- The core ledger utilizes a Dimensional Chart of Accounts (CoA), avoiding the clutter of thousands of hardcoded account combinations. Transactions are tagged with dynamic dimensions (e.g., Project, Department, Location) injected by native modules or external integrations.

### 3.2. Multi-Entity & Consolidations
- **The Mapping Model:** To support groups of companies, each subsidiary can maintain its own unique Chart of Accounts. 
- **Automated Consolidations:** At month-end, the system utilizes predefined templates to map subsidiary accounts up to a Master Consolidation Ledger, seamlessly handling inter-company eliminations.

### 3.3. Immutability & Audit Trails (The "Lock" System)
The system balances startup agility with enterprise audit requirements through a dual-mode lock system:
- **Default Mode (Month-End Lock):** Users can soft-edit or delete records during the active month. Upon executing the "Month-End Close," the period is locked permanently. Any subsequent changes to that period require strict reversing journals.
- **Strict Enterprise Mode (One-Way Toggle):** For mature or funded companies requiring absolute audit trails, this mode can be activated. Once turned on, it is irreversible. All posted journals and invoices instantly become immutable, and any correction requires a formal reversing journal.

## 4. Multi-Currency & Localization

### 4.1. Global Currency Engine
- Support for all global fiat currencies.
- **Automated FX Journals:** The system automatically calculates and posts Realized and Unrealized Foreign Exchange (FX) Gain/Loss journal entries upon payment application and at month-end revaluations.

### 4.2. Localized Tax Engines
- The system architecture allows for unlimited localized tax engines.
- **Initial Launch:** The initialization wizard will offer native configurations for **Australia (AU)** (GST/BAS handling) and **New Zealand (NZ)** (GST returns).

## 5. The "Contextual AI CFO"
The platform incorporates an intelligence layer designed to help everyday users run their business with the rigor of a seasoned CFO.
- **Financial Calendar Driven:** The AI does not overwhelm the user. It surfaces guidance contextually based on the day, week, or month (e.g., prompting Balance Sheet reconciliations ahead of month-end).
- **Proactive Analysis:** It provides natural-language analysis of the PnL, Balance Sheet, and Cash Flow.
- **Forecasting:** Evaluates past and present data to provide actionable alerts on what the business should prepare for in the coming periods.

## 6. Onboarding & Implementation
- Implementation does *not* rely on unpredictable AI. 
- Customers are guided through a highly curated series of configuring questions (e.g., entity type, industry). 
- Based on these inputs, predefined templates dictate the initial system configuration, workflow rules, and approval hierarchies, ensuring a flawless "off-the-shelf" deployment with controlled flexibility.

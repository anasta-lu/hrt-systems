# SDLC Phase 11: Development Standards & Documentation Strategy

This document formally captures the coding, commenting, and documentation standards required when HRT Systems transitions from the Planning phase into the Development phase.

## 1. Code Commenting & Explanation Standards
To ensure the founder and internal team have full visibility and understanding of the codebase, all code generated during the development phase must adhere to the following strict standards:

*   **100% Commented Code:** Every function, class, and critical logical step must be heavily commented. The comments must explain *why* the code is written a certain way, connecting it back to the Accounting Kernel rules defined in the SDLC.
*   **Process Explanations:** At the top of every file, there must be a plain-English docstring explaining exactly what the file does and how it interacts with other files within the development folder (e.g., "This file receives the API payload from `router.py` and passes it to the `ledger_entries` database model").

## 2. End-User & Admin Documentation Strategy
The software is only as good as the team's ability to use it. Alongside the codebase, a comprehensive suite of manuals will be developed.

### 2.1. The Implementation & Setup Guide
*   **Target Audience:** System Administrators and Onboarding Specialists.
*   **Content:** Step-by-step procedures for initializing a new tenant. This covers configuring the Chart of Accounts, setting up the Dynamic Dimensions, defining the Segregation of Duties (SoD) roles, and toggling the Tax Engine settings for AU/NZ.

### 2.2. The Internal Staff Operations Manual
*   **Target Audience:** End-users (e.g., AR Clerks, AP Managers, Warehouse Staff).
*   **Content:** Procedural guides on how to execute daily tasks within the Universal Workflow UI (e.g., "How to process a Supplier Invoice," "How to reconcile a bounced payment"). This manual focuses entirely on the operational screens, shielding non-finance staff from the complex accounting happening underneath.

### 2.3. The Policy & Compliance Manual
*   **Target Audience:** Financial Controllers and External Auditors.
*   **Content:** Documentation proving how the system enforces AASB/IFRS standards, detailing the Period Close locks, the Audit Evidence Hashing mechanics, and how to use the Read-Only Auditor Portal (PBC module).

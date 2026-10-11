# Phase 6: Security, Controls & Compliance Architecture

This phase defines the governance, anti-fraud, and audit capabilities of HRT Systems. As per the Master Context, the core principle is: *"Admin configurability cannot bypass accounting invariants."*

## 1. Segregation of Duties (SoD) Engine
To provide enterprise-grade fraud prevention, the system enforces Segregation of Duties mathematically, preventing a single actor from controlling an entire financial lifecycle.

*   **Conflict Matrices:** The system prevents the assignment of conflicting roles to the same user.
    *   *Example Conflict:* `Supplier_Master_Data_Manager` (can create bank accounts) + `AP_Payment_Approver` (can release funds). 
*   **Transactional SoD & The Sole Operator Exception:** For larger teams, if User A creates Supplier X, the system mathematically locks User A from approving any payments to Supplier X. 
    *   *Sole Operator Exception:* To prevent blocking legitimate small businesses, the system dynamically checks the tenant's user count. If there is only one active user account (the Master Admin), the system automatically suspends strict SoD blocking, allowing the sole trader to process end-to-end transactions (while continuing to log an immutable audit trail of every action).
*   **Privileged Action Logging:** Any attempt to bypass SoD (e.g., a CEO overriding a lock) is flagged as a `ControlEvent` and permanently highlighted on the external Audit Log.

## 2. Advanced RBAC & Data Scopes
Permissions in HRT Systems are multi-dimensional. A user's access is defined by:
`Action` + `Resource` + `Data Scope`

*   **Actions:** Create, Read, Update, Approve, Void, Post.
*   **Resources:** Supplier Invoices, Bank Feeds, Accounting Periods, Master Data.
*   **Data Scopes (The Differentiator):** Users are restricted not just by *what* they can do, but *where* they can do it.
    *   *Entity Scope:* User can only see 'Subsidiary B'.
    *   *Dimensional Scope:* A Project Manager can only see AP Invoices tagged to `Project: Alpha`. They cannot see the wider company PnL.

## 3. The Immutable Audit Trail (Provenance)
HRT Systems guarantees a perfect, unbroken lineage from the Financial Statements down to the raw physical evidence. 

**The Traceability Chain:**
`Financial Statement Line` → `GL Account Balance` → `Ledger Entry` → `Accounting Event` → `Subledger Transaction` → `Business Event` → `Source Document PDF`

*   **Evidence Hashing:** When a Source Document (e.g., an AP Bill PDF) is uploaded, the system generates a cryptographic hash of the file. This hash is stored on the `business_events` table (`evidence_reference`). If a user alters the PDF in the AWS S3 bucket later, the hash will break, instantly flagging the document as tampered.
*   **No Hard Deletes:** As defined in Phase 4, `ON DELETE RESTRICT` is enforced at the database level. Even a system administrator with root database access cannot seamlessly delete a posted journal without leaving massive orphaned records in the event tables.

## 4. The Auditor Portal & PBC (Provided by Client) Workflow
External audits are historically painful (the "Month-End Panic"). HRT Systems productizes the audit process.

*   **Read-Only Auditor Access:** Auditors are granted a specific scoped role (`External_Auditor`). They can view the GL, drill down to the hashed source documents, and run reports, but have zero write access.
*   **PBC (Provided By Client) Integration:** Instead of using spreadsheets and email to manage audit requests, the system has a native PBC module. 
    *   The auditor flags a sample of 50 transactions in the UI.
    *   This generates a PBC Request ticket for the internal finance team.
    *   The internal team attaches justifications/memos directly to the ticket, linking them to the system's `business_events`.
*   **Audit Adjustments:** If the auditor mandates an adjustment, it is posted using a specific `AuditAdjustmentJournal` type, ensuring it is clearly separated from standard operational flow and flagged in the `AccountingPeriodReopened` control event if the period was already locked.

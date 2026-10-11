# Phase 8: API & Integration Architecture

This phase defines the technical integration layer for HRT Systems. Following the Master Context mandate: *"Native Integration, Not Taped-Together Modules,"* the system is designed API-first using FastAPI and Temporal.io.

## 1. The API-First Philosophy (Hub & Spoke)
HRT Systems does not have a "hidden" backend for its own UI. The exact same REST/GraphQL APIs that power the React frontend are exposed to external integrators and clients.

*   **Idempotency by Default:** Every API POST/PUT endpoint requires an `Idempotency-Key` header. If an external system (e.g., Salesforce) drops a connection and retries pushing an invoice 3 times, FastAPI catches the key and ensures the `business_event` is only created once.

## 2. Integration Architecture (Temporal.io)
HRT Systems relies on Temporal.io to manage external integrations (like Payroll, Stripe, or Asana), ensuring that dropped connections do not result in missing financials.

*   **The Ingestion Flow:**
    1.  **Trigger:** Webhook received from HubSpot (e.g., Deal Won).
    2.  **FastAPI Buffer:** FastAPI instantly returns a `202 Accepted` to HubSpot, preventing timeouts, and places the payload onto a queue.
    3.  **Temporal Orchestration:** Temporal picks up the payload, standardizes it into a `business_event` (e.g., `CustomerInvoiceIssued`), and attempts to map the dimensions (e.g., HubSpot Region -> HRT Systems Dimension).
    4.  **Dead-Letter/Replay:** If Temporal fails to map a dimension (e.g., the Region is misspelled), the workflow pauses and alerts an admin. The admin fixes the spelling in the UI, and Temporal *resumes* the exact workflow from where it paused, without requiring HubSpot to resend the data.

## 3. The "No Direct GL Writes" Rule
A strict invariant of the architecture is that integrations **cannot** write directly to the General Ledger or the `accounting_events` table. 

*   External systems (like Employment Hero or a bespoke manufacturing tool) can only submit `business_events` via the API. 
*   This forces all external data to pass through the HRT Systems internal Accounting Kernel rules engine, ensuring compliance, tax calculations, and period-close locks are mathematically respected.

## 4. Webhooks & Event Streaming
To act as a true operational hub, HRT Systems pushes data out as fast as it takes it in.
*   The system uses an outbox pattern. When an `accounting_event` is successfully posted, a corresponding webhook is fired to notify external systems (e.g., notifying the external CRM that the customer's invoice status is now `PAID`).

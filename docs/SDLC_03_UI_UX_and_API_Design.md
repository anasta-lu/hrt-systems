# SDLC Phase 3: UI/UX & API Design Specifications

To successfully execute the "Financial Hub" strategy, the system must balance complex backend integrations with an incredibly intuitive user interface. The UI must feel as simple as Xero, while the APIs provide the horsepower of a mid-market ERP.

## 1. UI/UX Core Principles

### 1.1. The "Consumerized" ERP Experience
Traditional ERPs expose their complex database structures directly to the user UI. Our UI will abstract this.
- **Progressive Disclosure:** Users only see advanced fields (like Dimensions) if they need them.
- **Design System:** Use a modern component library (e.g., Tailwind UI, MUI, or Radix) to ensure a clean, fast, single-page application (SPA) feel.

### 1.2. The Hub Dashboard
Because the core value proposition is being a financial aggregator, the primary dashboard must reflect integration health and unbilled operational data.
- **Key Widgets:**
  - **Unbilled Integration Revenue:** "You have $14,000 of unbilled time sitting in Asana."
  - **Integration Health:** Real-time status lights for connected apps (e.g., "Monday.com: Syncing | HubSpot: Connected").
  - **Cash Flow vs. Pipeline:** Comparing actual cash in the bank against the sales pipeline pulled from the CRM.

### 1.3. The "Mapping Engine" UI
This is the most critical UI component of the system. Users must be able to map data from Monday/Asana into the Dimensional General Ledger without writing code.
- **Visual Mapping Interface:** A drag-and-drop or dropdown interface where a user can say:
  - "When Monday.com *Item Status* = 'Done'" -> "Trigger Event: Create Unbilled Time Entry".
  - "Map Monday.com *Board Name*" -> "ERP Dimension: Department".
  - "Map Monday.com *Client Column*" -> "ERP Dimension: Customer".

---

## 2. API Design Specifications

The APIs are split into two distinct layers: The **Frontend API** (drives our React/Vue UI) and the **Ingestion API** (receives data from Monday, Asana, etc.).

### 2.1. The Frontend API (Internal REST)
Used strictly by our web application.
- **Format:** standard JSON over REST.
- **Pagination:** Cursor-based (`?cursor=xyz&limit=50`) for smooth infinite scrolling on large ledgers.
- **Example Endpoint:** `GET /api/v1/ui/journals`

### 2.2. The Ingestion API (External Webhooks & Sync)
This API is designed to receive high-volume data from external apps. It must be exceptionally fast and never timeout.
- **Pattern:** Asynchronous "Fire and Forget".
- **Security:** HMAC signature verification to ensure the payload actually came from Monday/Asana.

**Endpoint:** `POST /api/v1/integrations/webhooks/monday`
**Payload Example:**
```json
{
  "event": "item_updated",
  "board_id": "12345",
  "pulse_id": "98765",
  "column_title": "Status",
  "value": { "label": "Done" },
  "user_id": "user_777"
}
```
**Response:** `202 Accepted` (The API acknowledges receipt instantly, drops it onto a queue, and Temporal picks it up for heavy processing in the background).

## 3. Standardization of External Payloads (The "Adapter Pattern")

Since every external tool formats data differently (Monday calls tasks "Pulses", Asana calls them "Tasks"), the API layer uses Adapters.

1. **Receive:** Webhook hits `POST /webhooks/asana`.
2. **Transform (Adapter):** The Asana adapter translates the Asana-specific JSON into our ERP's internal "Standard Operational Event" JSON.
3. **Process:** Temporal processes the "Standard Operational Event", totally unaware of whether the event originally came from Asana or Monday.

This makes adding *new* integrations in the future incredibly fast—you only have to write the translation Adapter, not a whole new billing workflow.

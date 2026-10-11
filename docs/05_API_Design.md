# API Design & Integration Architecture

For an ERP to overtake incumbents, it must have a world-class, developer-friendly API. The ecosystem (third-party apps connecting to your ERP) is what creates lock-in and long-term value.

## 1. Architectural Style: REST vs GraphQL
While GraphQL is excellent for frontend data fetching, **REST (or gRPC for internal services)** is strongly recommended for the core public financial APIs.
- **Predictability:** Financial operations (creating invoices, posting journals) are highly stateful and imperative. REST maps cleanly to these actions.
- **Caching:** REST leverages standard HTTP caching mechanisms well, which is useful for static data (like Tax Rates or Chart of Account templates).
- **Recommendation:** Use strictly versioned REST for the Public API. Consider GraphQL *only* for your internal UI dashboard where complex, aggregated views are needed.

## 2. The Golden Rule: Idempotency
In financial software, a network timeout can be catastrophic if not handled correctly. If a client attempts to post a $5,000 journal entry, and the network drops before they get a response, they might retry the request. Without idempotency, they just posted $10,000.

**Implementation:**
- Every POST/PUT API endpoint must require an `Idempotency-Key` header.
- The backend stores this key against the transaction.
- If a request comes in with a previously seen key, the server intercepts it and returns the cached response of the original successful request, *without* executing the business logic again.

```http
POST /api/v1/journals
Idempotency-Key: 123e4567-e89b-12d3-a456-426614174000
Authorization: Bearer <token>

{
  "date": "2026-09-20",
  "lines": [...]
}
```

## 3. Webhooks & Event Subscriptions
To build an ecosystem, third-party apps need to know when things happen in your ERP.
- Implement a robust Webhook Engine.
- **Events to publish:** `invoice.created`, `invoice.paid`, `contact.updated`, `journal.posted`.
- Ensure webhook delivery guarantees (retry with exponential backoff) and payload signing (HMAC-SHA256) so clients can verify the event came from your system.

## 4. API Gateway & Rate Limiting
Because multiple tenants share infrastructure, one aggressive third-party app cannot be allowed to bring down the system (Noisy Neighbor problem).
- Place an API Gateway (e.g., Kong, AWS API Gateway) in front of the services.
- Implement strict rate-limiting per `tenant_id` and per `client_id` (e.g., 60 requests per minute).
- Use a Leaky Bucket or Token Bucket algorithm via Redis.

## 5. Pagination and Bulk Operations
Accounting systems handle massive lists (millions of journal lines).
- **Pagination:** Do not use `OFFSET/LIMIT` for large datasets as it degrades database performance. Use **Cursor-based pagination** (e.g., `?starting_after=last_id&limit=100`).
- **Bulk Endpoints:** Provide `/api/v1/journals/bulk` endpoints. Creating 1,000 journal entries via 1,000 separate HTTP requests is inefficient. Accept batches, process them in a single database transaction, and return partial success/failure reporting.

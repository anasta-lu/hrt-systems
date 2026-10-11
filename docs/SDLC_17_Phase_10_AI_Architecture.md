# Phase 10: AI Architecture (The HRT Assistant)

This phase defines the role of Artificial Intelligence within HRT Systems. As mandated by the Master Context: *"AI sits above deterministic accounting truth. AI must not silently override controls or accounting rules."*

## 1. The AI Boundary (Strict Read-Only Permission)
Accounting is a deterministic discipline (1 + 1 must always equal 2). LLMs (Large Language Models) are probabilistic (they guess the next best word). Mixing them dangerously leads to hallucinations in financial data.

Therefore, the **HRT Assistant** operates with **STRICT READ-ONLY permissions**. It can provide high-level assistance, surface insights, and query data, but it mathematically cannot write, edit, or delete any data within the system.

## 2. HRT Assistant Capabilities & Custom Reporting
Because the HRT Assistant has read-only access to the underlying database (via the Semantic Layer), it can instantly generate custom reports on request without risking data integrity:
*   **Custom Report Generation:** A user can ask, "Show me a table of all marketing expenses in Q2 broken down by Project," and the Assistant will query the database and render a custom report on the fly.
*   **Anomaly Detection:** "Your Software Subscriptions expense jumped 45% this month compared to the historical average. Would you like me to list the new vendors?"
*   **Cash Flow Forecasting:** Analyzing the AR Aging subledger and historical payment velocities to predict when cash will actually hit the bank.
*   **Month-End Bottleneck Analysis:** "The month-end close is currently delayed. There are 14 unapproved AP Bills sitting with the Marketing Manager."

## 3. Workflow Enrichment (The AI Assistant)
While the AI cannot post a journal, it acts as a hyper-intelligent assistant during the `VALIDATE` and `ENRICH` stages of the Universal Workflow.
*   **OCR & Classification:** When a user uploads a receipt, the AI extracts the vendor, amount, and suggests the GL Account and Dimensions based on historical patterns (e.g., "You usually tag Uber receipts to 'Travel' and 'Sales Dept'").
*   **Drafting Explanations:** During an audit, if a variance is flagged on a PBC ticket, the AI can draft an explanation by reading the underlying business events and linking to the source documents, ready for human approval.

## 4. Contextual Prompting via the Semantic Model
When a user asks the AI CFO a question (e.g., "What was our margin on Project Alpha?"), the system uses Retrieval-Augmented Generation (RAG). 
1. The AI translates the user's natural language into a structured query targeting the Semantic Model.
2. The Semantic Model runs the deterministic SQL query against the `ledger_entries`.
3. The exact, mathematically correct number is passed back to the AI.
4. The AI wraps the correct number in a natural language explanation, ensuring zero hallucinations.

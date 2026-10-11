# Radical TG Control Plane (Master Admin Orchestrator) Concept

This document drafts the conceptual architecture for the **Radical TG Control Plane**—a separate, overarching "Master Admin" application owned and managed exclusively by **Radical TG**. It is designed to oversee, monitor, and provision all individual HRT Systems (the customer tenants) across the entire software fleet. 

## 1. Architecture: Control Plane vs. Data Plane
To manage a fleet of enterprise ERPs, the architecture must separate the management layer from the operational software.
*   **The Data Plane (HRT Systems):** The individual ERP instances running for clients. This is where the accounting kernel, GL, and UX live.
*   **The Control Plane (Master Admin App):** A separate, highly secure internal SaaS application used exclusively by HRT internal staff and support teams. 

## 2. Fleet Management & Automated Provisioning
The Control Plane acts as the infrastructure orchestrator.
*   **Provisioning via API:** When a new customer signs up, the Control Plane fires API calls to the infrastructure providers (e.g., AWS, Vercel, GitHub). It automatically provisions a new isolated PostgreSQL schema (or database), sets up the frontend hosting, and initializes the baseline accounting configurations.
*   **Centralized Deployment (Zero Version Drift):** We cannot afford to have different versions of HRT Systems running in the wild. All code updates, database migrations, and new features MUST be committed and pushed through the Radical TG Master Admin. The Control Plane acts as the singular deployment orchestrator, rolling the update out to all active client instances simultaneously to guarantee 100% version parity across the fleet.

## 3. Environment Cloning (Bug Testing & Sandbox)
Enterprise software requires rigorous support mechanisms. You cannot test a bug in a client's live production ledger.
*   **One-Click Cloning:** A support engineer can click "Clone to Sandbox" on a specific tenant in the Control Plane. 
*   **The Process:** The Control Plane securely copies the client's production database, scrubs any PII (Personally Identifiable Information like employee bank accounts), and spins up an isolated, temporary HRT System instance. Engineers can test bugs or new features on exact replica data without touching production.

## 4. Telemetry & Health Monitoring
To provide proactive customer service, the Control Plane must know if a client's system is failing before the client calls support.
*   **The Local Status Page:** Every individual HRT System has a built-in `admin/health` module. This module monitors database latency, API error rates, and Temporal worker status.
*   **The Telemetry Heartbeat:** The local system pushes a "heartbeat" payload up to the Control Plane every 60 seconds.
*   **The Global Dashboard:** The Control Plane displays a massive grid of all active HRT Systems. If Tenant 104's Temporal worker crashes, their row turns red on the Control Plane, alerting HRT staff immediately.

## 5. Model Context Protocol (MCP) Integration
To supercharge your internal support team, the Control Plane will expose its management API via the **Model Context Protocol (MCP)**.
*   **AI-Driven Support:** This allows internal AI agents to natively interact with your infrastructure. 
*   **Example Use Case:** A support agent can type into their AI chat: *"Tenant 104 is reporting an API error. Spin up a clone of their environment and pull the last 50 error logs."* Because the Control Plane is MCP-enabled, the AI can securely execute the cloning script, fetch the logs, and summarize the bug for the human engineer instantly.

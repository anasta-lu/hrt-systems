# HRT Systems

Full-suite ERP for small and medium businesses: Xero-simple on the surface, enterprise-grade underneath.

## Tech stack
- **Backend:** Python + FastAPI (modular monolith)
- **Database:** PostgreSQL (shared schema + RLS for Standard tier, schema-per-tenant for Pro tier)
- **Workflows & integrations:** Temporal.io
- **Frontend:** React / Next.js

See `docs/SDLC_02_Technical_Architecture_Blueprint.md` and `docs/SDLC_14_Phase_7_UX_UI_Architecture.md`.

## Layout
| Folder | Contents |
| --- | --- |
| `docs/` | Product, architecture and SDLC documents |
| `db/sql/` | PostgreSQL schema scripts |
| `backend/` | FastAPI application and Temporal workers |
| `frontend/` | Next.js web app |

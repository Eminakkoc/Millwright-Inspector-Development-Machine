---
id: 55555555-5555-4555-8555-555555555555
todo-list-id: 22222222-2222-4222-8222-222222222222
todo-item-ids: [JWT-001, JWT-002]
commits: []
---

# Requirements — auth-jwt

Implement signed JWT verification on every protected request, replacing the legacy session-cookie flow. Tokens are RS256, signed by the auth service.

## Goals (this cycle)

- **JWT-001 — Verify and refresh JWT tokens on protected routes.** Seam: `services/auth/middleware.ts`. The middleware reads the `Authorization: Bearer <token>` header, verifies the signature against the cached JWKS, and refreshes the token via the `/auth/refresh` endpoint when expiry is within the rolling-refresh window (5 minutes).
- **JWT-002 — Reject expired tokens with a structured error.** Seam: `services/auth/errors.ts`. Expired or malformed tokens return HTTP 401 with `{ "code": "auth.token.expired" }`.

## Planned (future cycles)

- **JWT-003 — Migrate the `/auth/login` flow off session cookies entirely.** Will follow once JWT-001/002 ship.

## Non-goals (out of scope)

- Mobile clients remain on the legacy session flow until the mobile team picks up JWT-003.

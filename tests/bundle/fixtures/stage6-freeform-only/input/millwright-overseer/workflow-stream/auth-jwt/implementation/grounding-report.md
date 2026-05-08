---
id: 77777777-7777-4777-8777-777777777777
feature: auth-jwt
seam-classification: backend
---

# Codebase-grounding report — auth-jwt

## Per-item findings

### JWT-001 — Verify and refresh JWT tokens on protected routes

- **Seam:** `services/auth/middleware.ts` (existing files: `services/auth/middleware.ts`, `services/auth/jwks-cache.ts`).
- **Pre-existing components:** `JwksCache.getKey(kid)`, `AuthRequest.user` typed extension on `Request`.
- **Cycle flavor:** improvement.
- **Notes:** middleware currently handles only the legacy session cookie; extend it to fall through to bearer-token verification when a `Bearer` header is present. Keep both paths active during the migration.

### JWT-002 — Reject expired tokens with structured 401

- **Seam:** `services/auth/errors.ts` (existing files: `services/auth/errors.ts`, `lib/http/error-envelope.ts`).
- **Pre-existing components:** `errorEnvelope({ code, message })`, `AuthError` base class.
- **Cycle flavor:** improvement.
- **Notes:** add `AuthTokenExpiredError extends AuthError`; route the middleware's catch into the existing envelope serializer; do not reinvent the response shape.

## Overall seam summary

- Both items land in the existing `services/auth/` seam — no new top-level module needed.
- `services/auth/jwks-cache.ts` is load-bearing: bypassing it caused a 2026-Q1 partial outage.
- The structured error envelope is a project-wide rule; the new error class must serialize through it.

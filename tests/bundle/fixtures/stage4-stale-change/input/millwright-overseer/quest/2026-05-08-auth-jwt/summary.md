---
id: 33333333-3333-4333-8333-333333333333
todo-list-id: 22222222-2222-4222-8222-222222222222
features: [auth-jwt]
keywords: [auth]
description: Auth feature
---

# Summary

## Cross-cutting constraints

- All response bodies on auth-related routes must follow the structured-error envelope (`{ code, message }`) — discussed at the security review on 2026-04-30.
- Token verification must complete in under 5ms p99 — the auth service is on the request path for every protected endpoint.

## Feature: auth-jwt

The auth team has been on legacy session cookies since the original launch. The push to JWT was driven by two needs: (1) a forthcoming integration with a partner SaaS that requires bearer tokens, and (2) the move toward stateless API gateways internally.

Acceptance hints from the journal:
- The `/auth/refresh` endpoint already exists; it issues a fresh signed token given a valid refresh token. JWT-001 should reuse it, not duplicate refresh logic.
- The JWKS endpoint is `https://auth.internal/.well-known/jwks.json` and is cached for 10 minutes.

## Sources

- `journal/auth-jwt/feature.md`: original problem statement and acceptance hints.

# auth-jwt — agent handoff brief

> You are picking up work on a software feature. This document is
> self-contained: every fact you need to act is below. Do not assume
> access to files, repositories, or systems referenced inside any
> quoted material — only the prose in this brief is reliable.
>
> This brief was *extracted* from project planning records, not
> rewritten. Internal file paths and record names have been replaced
> with placeholders (`<internal path>`, `<an internal record>`); if
> you see those, you do not have access to what they refer to — ask
> the human if it matters.
>
> Some bullets may still use technical phrasing or refer to roles or
> tooling from the originating system. Read such phrasing charitably
> as natural language; nothing in this brief depends on you knowing
> what those terms mean.
>
> If you need to inspect specific code, diffs, or diagrams, ask the
> human who shared this brief; this document does not include them.
>
> If you are asked to review the work, focus on the "Requirements
> and constraints", "Out of scope", and "Open review findings"
> sections. If you are asked to continue the work, focus on "What
> the next agent should do".

## Custom project instructions

When verifying tokens, prefer the existing `services/auth/jwks-cache.ts` helper over instantiating a new JWKS client. The cache is shared across requests and is on the hot path; bypassing it caused a partial outage in 2026-Q1.

## Project-wide constraints

- All response bodies on auth-related routes must follow the structured-error envelope (`{ code, message }`) — discussed at the security review on 2026-04-30.
- Token verification must complete in under 5ms p99 — the auth service is on the request path for every protected endpoint.

## Feature background

The auth team has been on legacy session cookies since the original launch. The push to JWT was driven by two needs: (1) a forthcoming integration with a partner SaaS that requires bearer tokens, and (2) the move toward stateless API gateways internally.

Acceptance hints from the journal:
- The `/auth/refresh` endpoint already exists; it issues a fresh signed token given a valid refresh token. JWT-001 should reuse it, not duplicate refresh logic.
- The JWKS endpoint is `https://auth.internal/.well-known/jwks.json` and is cached for 10 minutes.

## Implementation rules to follow

- structured-error-envelope: every 4xx response must use `{ code, message }` per the security review on 2026-04-30
- no-direct-jwks-fetch: route every JWKS read through `services/auth/jwks-cache.ts`

## Objective

Implement signed JWT verification on every protected request, replacing the legacy session-cookie flow. Tokens are RS256, signed by the auth service.

## Scope in this session

- Verify and refresh JWT tokens on every protected request. (item JWT-001).
- Reject expired tokens with a structured 401 error body. (item JWT-002).

## Requirements and constraints

- **JWT-001 — Verify and refresh JWT tokens on protected routes.** Seam: `services/auth/middleware.ts`. The middleware reads the `Authorization: Bearer <token>` header, verifies the signature against the cached JWKS, and refreshes the token via the `/auth/refresh` endpoint when expiry is within the rolling-refresh window (5 minutes).
- **JWT-002 — Reject expired tokens with a structured error.** Seam: `services/auth/errors.ts`. Expired or malformed tokens return HTTP 401 with `{ "code": "auth.token.expired" }`.

## Planned for future work

The implementation must keep architectural room for the following items, which will be delivered in later cycles (not in this session):

- **JWT-003 — Migrate the `/auth/login` flow off session cookies entirely.** Will follow once JWT-001/002 ship.

## Out of scope

- Mobile clients remain on the legacy session flow until the mobile team picks up JWT-003.

## Decisions already made

- **2026-05-07** — Treat `legacy-auth` module as out-of-scope. Reason: pending migration owned by another team.

## Existing system context

The implementation builds on the following pre-existing parts of the codebase:

- **Item JWT-001 — Verify and refresh JWT tokens on protected routes**
  - **Seam:** `services/auth/middleware.ts` (existing files: `services/auth/middleware.ts`, `services/auth/jwks-cache.ts`).
  - **Pre-existing components:** `JwksCache.getKey(kid)`, `AuthRequest.user` typed extension on `Request`.
  - **Cycle flavor:** improvement.
  - **Notes:** middleware currently handles only the legacy session cookie; extend it to fall through to bearer-token verification when a `Bearer` header is present. Keep both paths active during the migration.

- **Item JWT-002 — Reject expired tokens with structured 401**
  - **Seam:** `services/auth/errors.ts` (existing files: `services/auth/errors.ts`, `lib/http/error-envelope.ts`).
  - **Pre-existing components:** `errorEnvelope({ code, message })`, `AuthError` base class.
  - **Cycle flavor:** improvement.
  - **Notes:** add `AuthTokenExpiredError extends AuthError`; route the middleware's catch into the existing envelope serializer; do not reinvent the response shape.

- **Overall:**
  - Both items land in the existing `services/auth/` seam — no new top-level module needed.
  - `services/auth/jwks-cache.ts` is load-bearing: bypassing it caused a 2026-Q1 partial outage.
  - The structured error envelope is a project-wide rule; the new error class must serialize through it.

## Implementation summary

**Entrypoints introduced or modified**

- `services/auth/middleware.ts:authMiddleware` — request-path middleware, runs on every protected route.

**End-to-end flows**

- Bearer token request: `authMiddleware` → `JwksCache.getKey` → `jwt.verify` → request continues with `req.user` set.
- Expired token request: `authMiddleware` catches `JwtExpiredError` → emits `AuthTokenExpiredError` → existing envelope serializer → 401 response.

## Changed areas

> ⚠ The change summary below was generated for an earlier commit range and may not reflect the latest commits. Recorded range: `<SHA>..<SHA>`. Current range: `<SHA>..<SHA>`.

- services/auth/middleware.ts (+45/-3): wires Bearer-token verification into the existing session-cookie middleware..
- services/auth/errors.ts (+18/-0): adds `AuthTokenExpiredError`, serialized through the existing envelope..
- services/auth/jwks-cache.ts (+5/-2): tiny patch — exposes `getKey` directly (was internal)..

Changed but purpose not annotated. Ask the human if these matter for your task:

- tests/auth/middleware.test.ts (+120/-0)

## Open review findings

- *(unclassified)*: The new middleware doesn't seem to read the JWKS cache the way the rule says it should — there's a fallback path I want to look at more closely.
- *(unclassified)*: Also the error envelope shape is consistent now, which is good. Just want to double-check that the error code string matches what the partner SaaS expects in their integration tests.

## What the next agent should do

Address the open review findings in priority order (blockers first). For each, propose the smallest change that resolves the finding without expanding scope.

---

> _This brief was extracted from project planning and review records for feature **auth-jwt** **during review** on **<TIMESTAMP>**. The originals (not included): planning records, codebase-context audit, change index, manual verification plan and results, and any open review findings. The brief above is an extract; the originals remain authoritative._

---
id: 99999999-9999-4999-8999-999999999999
requirements-id: 55555555-5555-4555-8555-555555555555
---

# Inspector review — auth-jwt

## Implementation Review

### IR-001 — Bearer middleware bypasses jwks-cache for the cold path

- severity: major
- scope: re-implement
- status: open
- details: |
    The cold-path branch in services/auth/middleware.ts calls `new JwksClient()` directly
    instead of routing through services/auth/jwks-cache.ts. This violates the no-direct-jwks-fetch
    rule and re-introduces the failure mode that caused the 2026-Q1 partial outage.
- fix-note:

### IR-002 — Token refresh edge case at the rolling-window boundary

- severity: minor
- status: open
- details: |
    A token whose expiry lands exactly at the 5-minute refresh boundary is currently rejected
    with 401 instead of being refreshed. Either widen the comparison to `<= 5min` or document
    the strict inequality as intentional.
- fix-note:

---
id: 99999999-9999-4999-8999-999999999999
requirements-id: 55555555-5555-4555-8555-555555555555
---

# Overseer review — auth-jwt

## Implementation Review

The new middleware doesn't seem to read the JWKS cache the way the rule says it should — there's a fallback path I want to look at more closely.

Also the error envelope shape is consistent now, which is good.

### IR-001 — Cold-path bypasses jwks-cache

- severity: major
- scope: re-implement
- status: open
- details: |
    Confirmed during review: the cold-path branch creates a new JwksClient directly.
- fix-note:

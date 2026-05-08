---
id: 88888888-8888-4888-8888-888888888888
requirements-id: 55555555-5555-4555-8555-555555555555
feature: auth-jwt
base-commit: "0000000000000000000000000000000000000000"
head: "1111111111111111111111111111111111111111"
---

# Change summary — auth-jwt

## Range

- base-commit: `0000000000000000000000000000000000000000`
- head: `1111111111111111111111111111111111111111`
- commit count: 3

## Changed files

- services/auth/middleware.ts (+45/-3): wires Bearer-token verification into the existing session-cookie middleware.
- services/auth/errors.ts (+18/-0): adds `AuthTokenExpiredError`, serialized through the existing envelope.
- services/auth/jwks-cache.ts (+5/-2): tiny patch — exposes `getKey` directly (was internal).
- tests/auth/middleware.test.ts (+120/-0)

## Detected entrypoints

- `services/auth/middleware.ts:authMiddleware` — request-path middleware, runs on every protected route.

## Suspected flows

- Bearer token request: `authMiddleware` → `JwksCache.getKey` → `jwt.verify` → request continues with `req.user` set.
- Expired token request: `authMiddleware` catches `JwtExpiredError` → emits `AuthTokenExpiredError` → existing envelope serializer → 401 response.

## Omitted from analysis

- `dist/` build output.

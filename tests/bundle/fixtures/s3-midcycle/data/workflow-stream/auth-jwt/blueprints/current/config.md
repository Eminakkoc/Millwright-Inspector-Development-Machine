---
id: 66666666-6666-4666-8666-666666666666
requirements-id: 55555555-5555-4555-8555-555555555555
---

## Skills

- subagent-driven-development: per-task delegation for the middleware refactor; path: .claude/skills/subagent-driven-development/SKILL.md

## Rules

- structured-error-envelope: every 4xx response must use `{ code, message }` per the security review on 2026-04-30; path: .claude/rules/structured-error-envelope.md
- no-direct-jwks-fetch: route every JWKS read through `services/auth/jwks-cache.ts`; path: .claude/rules/no-direct-jwks-fetch.md

## Load on demand

## GIT BRANCH

feat/auth/jwt-middleware

## Inspector Additions

When verifying tokens, prefer the existing `services/auth/jwks-cache.ts` helper over instantiating a new JWKS client. The cache is shared across requests and is on the hot path; bypassing it caused a partial outage in 2026-Q1.

## Stage 2 — Blueprint approval

- **2026-10-05** — `var b` at src/x.js:2 is allowed on purpose: it is a legacy global that an old script reads through `window.b`, which `const` and `let` would break. Reason: compatibility shim, removed in a later feature.

# 0006 — gitleaks for pre-commit secret scanning

- Status: accepted
- Date: 2026-10-20

## Context

`docs/phases/phase-0-foundation.md` asks for `detect-secrets` or `gitleaks` in
`.pre-commit-config.yaml`, to catch an accidentally committed credential before it reaches
the public repo.

## Options

1. `detect-secrets` (Yelp) — plugin-based entropy/regex scanner. Needs a maintained
   `.secrets.baseline` file (generated once, reviewed and committed, regenerated whenever a
   known false positive is accepted) and a Python environment to run.
2. `gitleaks` — single Go binary, rule-based regex scanning via a built-in default ruleset.
   No baseline file to maintain by default; runs standalone, independent of the project's
   own Python environment.

## Decision

`gitleaks`. No baseline file to create and keep in sync, and it doesn't pull the secret
scanner into the project's own Python dependency chain — simpler to set up and maintain for
a solo project.

## Consequences

If a legitimate false positive shows up later (e.g. a fixture value that looks like a key),
it needs a `.gitleaks.toml` allowlist entry rather than a baseline edit.

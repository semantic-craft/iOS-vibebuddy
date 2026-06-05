# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

This repo is **single-context**: one `CONTEXT.md` and one `docs/adr/` at the root.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — the project's domain language.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The producer skill (`/grill-with-docs`) creates them lazily when terms or decisions actually get resolved.

## File structure

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-provider-agnostic-realtime-voice.md
│   ├── 0002-byo-key-direct-to-provider.md
│   ├── 0003-free-no-iap-no-tracking.md
│   ├── 0004-half-duplex-mic-gating-not-aec.md
│   ├── 0005-shared-kit-sessions-platform-audio.md
│   └── 0006-code-drawn-pet-and-menu-icon.md
└── (app sources)
```

> Note: a vendored copy of these skills lives under `vendor/mattpocock-skills/` and has its own `docs/adr/`. Ignore it — the authoritative domain docs are the root `CONTEXT.md` and root `docs/adr/`.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/grill-with-docs`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0004 (half-duplex mic gating, not AEC) — but worth reopening because…_

# ADR-0031: Grok Bot is an account-usage provider only

- Status: accepted
- Date: 2026-09-21
- Related: [ADR-0024](0024-dashboard-session-reader.md), [ADR-0030](0030-grok-build-hosted-over-acp.md)

## Context

VibeBuddy shipped an optional read-only observer for Grok Bot (the cloud bot
product opened by `com.anysphere.sand`, distinct from the Grok Build CLI). It
reused the official client's active-account gateway credentials to follow an SSE
stream, projected each bot into a Session, and surfaced waits, verified
completions and an app-level Jump.

That integration was never able to become useful. Replies and approvals stayed
in the official app, so every card it produced was read-only. Question
continuations, automated tasks and turns spanning a disconnect could not be
verified at all, so they held the source in degraded health by design. Against
that, the observer carried the largest maintenance surface of any source: an
undocumented private gateway, Electron `safeStorage` decryption, an
account-identity recheck on every event, and bespoke settlement rules in the
reducer, the notice ledger, the speech policy, the approval and wait-handling
gates and four jump call sites.

The account allowance is the part people actually use, and it is a small,
self-contained read of one documented-shape endpoint.

## Decision

**Grok Bot is a quota provider and nothing else.** VibeBuddy reads the
signed-in account's Sand allowance and displays it beside the other providers.

- Removed: `GrokBotMonitor`, the gateway connection and descriptor read,
  `GrokBotObservation`, `GrokBotJumper`, the **Observe Grok Bot tasks** setting,
  the gateway observation diagnostic, and every Grok Bot branch in session
  policy (approval eligibility, sound actions, session actions, wait handling,
  stop reasons, `canJump`, jump copy on Mac and iPhone).
- Kept: `GrokBotLocalAccount` (the account read the quota needs),
  `GrokBotUsageProvider`, `AccountUsageProvider.grokBot`, and the Usage settings
  section with its Keychain authorization button.
- `AgentKind.grokBot` stays so a quota row can carry the brand mark, and so a
  `?agent=grokbot` hook is rejected as undecodable instead of being mistaken for
  Claude Code.
- `ObservationSource.gateway` and `WaitHandling.macGrokBot` stay in their wire
  enums, marked as legacy, only so a cached snapshot written by an older build
  still decodes. Nothing produces them.
- A lifecycle journal written by an older build can still hold Grok Bot rows.
  Nothing observes them any more, so they would never move or end; they are
  dropped on restore rather than restored as permanently stuck tasks.

## Consequences

Grok Bot tasks are followed in the official app. The Mac keeps showing the
weekly allowance, its reset and the account label, and the iPhone and Watch keep
relaying that quota — those paths are untouched.

One source of degraded observation health disappears, and the session reducer no
longer has an agent whose waits are unanswerable by construction.

Reviving task observation would mean re-deriving the gateway protocol against
whatever the official client does then; this ADR is a deliberate scope decision,
not a statement that the protocol stopped working.

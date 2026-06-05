# BYO key, audio direct to the provider, no vibebuddy cloud

**Status:** Accepted (2026-06-05)

The user brings their own API key (DashScope / OpenAI / Google), stored in the
Keychain; voice audio streams directly from the device to the user's chosen
provider. vibebuddy runs no server in the voice path and has no account. This
keeps the privacy story clean (no session or audio data through our servers) and
removes per-user inference cost, at the price of the user needing a key.

## Consequences

- The App Store privacy disclosure must state that audio goes to a third-party
  provider chosen by the user (see ADR-0003 and the privacy label).
- Voice must stay **optional** — the dashboard and approvals work with no key.

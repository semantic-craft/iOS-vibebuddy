# Daemon CLI-hook routes require the bearer token

**Status:** Accepted (2026-06-06) — implements `.scratch/daemon-security/issues/01`.

## Context

`VibeBuddyServer` binds `0.0.0.0:9876` so the Bonjour-paired phone can reach the
token-gated LAN routes (`/snapshot`, `/decision`, `/jump`, `/answer`, `/device`).
The CLI-hook routes (`/hook`, `/approval`, `/terminal`) were **unauthenticated**,
on the assumption they're localhost-only. But the listener is LAN-bound, so:

- any local process could POST `/hook` to spoof / delete sessions or fake an
  approval resolution; `/terminal` could hijack a session's terminal ref;
- a malicious web page (or DNS rebinding against the LAN IP) could reach the port
  — `curl`-shaped requests have no CORS and the routes ignore `Origin`.

The issue weighed three options: **A** token (+ origin) checks on the hook routes,
keeping one listener; **B** a second loopback-only listener; **C** a Unix domain
socket for the CLI path (open-vibe-island's model).

## Decision

**Option A.** The three CLI-hook routes now require the same per-install bearer
token as the phone routes. We keep the single `0.0.0.0` listener (the phone needs
LAN reach; binding the whole server to loopback would break it), because the token
alone closes the remote/browser/rebinding vectors — an attacker without the secret
can't post, regardless of origin.

The token is accepted **either** as an `Authorization: Bearer <token>` header
(script hooks: the forwarder, approval, capture, codex-notify, opencode plugin,
the Claude inline curl) **or** as a `?token=<token>` query param (native-http
hooks that can't set headers — Qwen). Both are checked by `hookAuthorized` in
`VibeBuddyServer`.

The secret is the existing file-based `TokenStore`
(`~/Library/Application Support/vibebuddy/token`, 0600) — the same token the phone
pairs with. Script hooks read it at runtime (rotating it needs no re-install);
the two baked clients (Claude inline command, Qwen URL) read it at install time.
Missing token → the request 401s and every hook swallows it (fail-open: a CLI is
never blocked).

## Consequences

- Forged / cross-origin `/hook`, `/approval`, `/terminal` are rejected; the paired
  phone is unchanged. Covered by tests in `VibeBuddyServerTests` (no-token and
  wrong-token 401; header and `?token=` accepted).
- **Residual:** another process running as the *same user* can read the 0600 token
  file and still post. That's the same-user threat the issue calls out as
  acceptable for A/B; only **C** (UDS + filesystem perms) closes it. Revisit C if
  the multi-CLI bridge is ever moved to a socket — it wants one forwarder anyway.
- Re-running the universal installer is needed once to re-bake the Claude inline
  command and the Qwen URL with the token; script-based hooks pick it up live.

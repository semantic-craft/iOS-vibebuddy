## vibebuddy for macOS — 1.1

Signed, notarized, and much better at telling you *why* it thinks an agent is
stuck. This is the first build that opens with a double-click — no Gatekeeper
warning, no `xattr` incantation — and the first one that can update itself.

### Agent observability

- **Codex Desktop, watched properly.** Session monitoring is now event-driven off
  the rollout file instead of polling, so a Codex session's state changes the
  moment it actually changes.
- **Collaboration and subagent topology.** A Claude Code session that spawns
  subagents, or a Codex task that fans out to collaborators, now shows its
  children — with names and counts — instead of one opaque row.
- **Observation source health.** Every session says how it is being observed
  (hook, rollout file, transcript) and admits when the signal is thin: a source
  that has gone quiet reads `degraded`, and a state nobody can vouch for reads
  `unknown` rather than a confident guess.
- **Notification delivery health.** A new Delivery view records what actually
  happened to each notification — `attempted`, `scheduled`, `accepted`,
  `failed` — so a notification that never arrived stops being a mystery.
- **Lifecycle journal.** A bounded, private log (7 days or 250 entries, mode
  0600) of session lifecycle events, so a session that vanished can be
  reconstructed after the fact.
- **Weekly usage.** Isolated adapters read your Codex and Claude plan usage
  read-only. Either one can be off or failing without affecting the other.

### Codex hooks

- Codex now integrates through its **official lifecycle hooks**
  (`~/.codex/hooks.json`), replacing the old notify-script shim. The bundled
  installer in Settings ▸ Setup writes and verifies the configuration for you.

### Distribution

- **Signed with a Developer ID and notarized by Apple.** First launch is a
  double-click.
- **Sparkle auto-update** is wired in this candidate. It becomes live only
  after this release is published with a signed appcast. On first launch the
  app asks once whether it should check for updates on its own; either answer
  is fine, and "Check for Updates…" in the menu is the manual path.

### Also

- The voice companion's call handling is shared between Mac and iPhone, so the
  two behave the same way.
- Consistent status wording across the Mac app, the iPhone app, and Codex Micro.

**Requires macOS 14 or later. Apple Silicon.**

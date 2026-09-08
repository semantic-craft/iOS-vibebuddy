# VibeBuddy 1.3.9

Mac direct distribution: 1.3.9 (16). iPhone and Apple Watch: 1.3.9 (20).

- Keep the compact MacBook Glance within the physical camera housing width, with visible status below the camera.
- Fix the menu panel collapsing its activity list, and anchor it correctly under the menu icon at screen edges.
- Add a searchable activity feed and direct controls for Dashboard, Glance, Settings and phone details.
- Require an explicit two-minute pairing window for new phones. Distinguish saved pairing from historical registration and push availability; forgetting phones survives restart.
- Update Codex and Claude Code hook integration, report inactive hook trust and app-server version drift, and preserve accurate waiting sources.
- Show complete Codex sandbox permission details and restrict these decisions to the current turn across Mac and iPhone approval surfaces.
- Preserve the iPhone working count while voice replaces the headline. This build includes the Watch companion and widgets.

## Integration limits

A healthy socket daemon does not prove ownership of Codex Desktop tasks. In the tested Desktop setup, a native approval was not mirrored as a VibeBuddy approval card; Desktop-origin remote approval remains unverified. The real daemon-owned permission relay is verified separately. MCP elicitation remains read-only.

Saved phone registration is not a live connection or notification-delivery guarantee. The Mac App Store edition is not included. iPhone and Watch availability depends on Apple's separate processing and review.

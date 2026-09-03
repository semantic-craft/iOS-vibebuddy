# dist/

Output of `tools/release-mac.sh`. Nothing here is committed (see `.gitignore`) —
every file is signed against one specific build:

| File | What it is |
|---|---|
| `vibebuddy-mac-v<version>.dmg` | the notarized, stapled disk image; upload as the `v<version>` GitHub Release asset |
| `appcast.xml` | the Sparkle feed; publish to the `gh-pages` branch, served at `SUFeedURL` |
| `vibebuddy-mac-v<version>.md` | copy of `docs/release-notes-<version>.md`; publish it to `gh-pages` next to `appcast.xml`, which links to it as the update's release notes |
| `*.delta`, `old_updates/` | `generate_appcast` bookkeeping for older versions |

Runbook: [`docs/sparkle-setup.md`](../docs/sparkle-setup.md).

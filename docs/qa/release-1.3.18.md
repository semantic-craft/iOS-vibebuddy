# Mac 1.3.18 acceptance

Mac build 30 contains the reviewed menu bar placement recovery from 7aa78f4a.

- Three focused MenuBarPlacementRecovery tests passed, including invalid saved placement, mixed-width displays, migration and preservation of intentional hiding.
- Release build passed before the version bump.
- A bundled SwiftUI MenuBarExtra probe repaired position 2588 on a 1710-point display to 180 and preserved an explicit hidden preference.
- The installed Developer ID candidate repaired the same invalid saved position, served a healthy daemon and displayed real agent data in its dashboard.
- Physical live display unplug/replug behavior is not claimed. AppKit owns live placement; display-change handling repairs only the saved preference.
- Distribution signing, notarization and final installation are verified separately during publication.

Local evidence: `.scratch/release-1.3.17/menu-placement-*`, `.scratch/menu-placement-runtime/scene-result-final.txt`. Research and ownership rationale: [menu-bar-placement-recovery.md](../research/menu-bar-placement-recovery.md).

Mobile remains TestFlight build 46. This Mac release does not close the remaining production Watch approval and restart acceptance gates.

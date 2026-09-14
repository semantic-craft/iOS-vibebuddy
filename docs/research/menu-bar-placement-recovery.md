# Menu bar placement recovery

## Failure and scope

On 2026-09-14 the installed app had one process, showMenuBarIcon=true, and a saved `NSStatusItem Preferred Position Item-0` of 2588 on a 1710-point display. Resetting that position to 180 and restarting restored the icon, confirmed by the owner. This establishes the startup recovery case, not every cause of a missing icon (notch crowding, third-party hiding, and system-wide menu hiding remain separate).

## Primary-source comparison

- [Apple autosaveName](https://developer.apple.com/documentation/appkit/nsstatusitem/autosavename-swift.property): explicit names identify saved status-item state; otherwise the system chooses a name. Use a stable application identity instead of depending indefinitely on `Item-0`.
- [Ice ControlItem](https://github.com/jordanbaird/Ice/blob/main/Ice/MenuBar/ControlItem/ControlItem.swift): one component owns each native item, configures its autosave name, and protects placement against removal side effects. Adopt that ownership boundary, not Ice's cross-application menu management or private layout constraints.
- [Hammerspoon menubar](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/menubar/libmenubar.m): restores preferred position before assigning the autosave name, and preserves saved placement during removal. Keep AppKit preference access isolated.
- [MenuBarExtraAccess 1.3.1](https://github.com/orchetect/MenuBarExtraAccess/tree/1.3.1): provides an NSStatusItem callback while retaining SwiftUI MenuBarExtra ownership. Pin this small MIT library to avoid a second menu implementation or locally maintained introspection. Its modifier must immediately follow MenuBarExtra.
- [Apple display-change notification](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification): use display events rather than periodic polling.

## Implementation contract

`MenuBarPlacementRecovery` is the only placement adapter. It migrates the old position to `VibeBuddy.MainMenu`, validates before attachment, and validates saved state on display changes. AppKit retains responsibility for live reflow; the adapter never removes a SwiftUI-owned item. The SwiftUI scene remains the sole item owner. The adapter keeps a weak reference, never starts another app/server, and preserves the user's show/hide preference.

Only negative, non-finite, or beyond-display positions are repaired. The hosting display is authoritative; a smaller secondary monitor must not reset a valid position on the primary. No display geometry means defer. The fallback is a right-side offset capped at 180 points and scaled down on small displays, not a machine-specific global coordinate.

The `NSStatusItem Preferred Position` key is an AppKit implementation detail also used by the referenced projects. Missing keys are left to macOS; this cannot guarantee every future macOS layout behavior. Tests must distinguish arithmetic, native adapter behavior, and physical display switching.

## Acceptance evidence

- Original installed-app recovery: owner confirmed icon returned.
- Pure regression tests: original 2588/1710 case, valid wide-display placement, normal placement, absent geometry and invalid values.
- Native probe: `.scratch/menu-placement-runtime/`; exercises actual NSStatusItem attachment and display-change notification. Current probe observes repaired defaults and retained item identity, but has not reproduced physical external-display removal.
- Experimental live removal was rejected: native visibility changes interfered with SwiftUI ownership in the isolated scene. The final adapter only changes saved placement and assigns the stable identity; it does not promise forced hot-plug recovery.
- Full app build/install checks are recorded under `.scratch/release-1.3.17/menu-placement-*`.

Final checks (2026-09-15): three focused XCTest regressions pass. The bundled SwiftUI scene probe reports `shown=true visible=true position=180.0`, then `hidden preference=false visible=false`. Final code review has no blocking findings. These checks prove startup placement/persistence and visibility preference behavior; they do not substitute for a physical display unplug test.

The final Release build passed and the Developer ID-signed local candidate was installed. Installed-app replay seeded the named position with 2588 before launch; startup repaired it to 180, showMenuBarIcon remained true, one app process served a healthy snapshot containing real agent sessions, and native Dashboard loaded. Public release assets were not changed by this local installation.

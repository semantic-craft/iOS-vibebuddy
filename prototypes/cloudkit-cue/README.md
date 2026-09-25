# CloudKit cue prototype (public-push ticket 01)

Throwaway prototype for ADR-0013 direction D. Its own bundle IDs
(`com.vibebuddy.cueproto`, `.nse`, `.mac`), its own container
(`iCloud.com.vibebuddy.cueproto`) and its own app group. No shipping target,
script or release path builds or links anything here.

| Part | What it does |
| --- | --- |
| `Mac/main.swift` (`CueProtoMac`) | Saves `Cue` records into the `Cues` zone of the signed-in user's private database, reads the phone's `Receipt` / `Action` / `Device` / `Delivered` records back through zone changes, deletes each cue once its receipt arrives, and serves `GET /time` + `POST /action` (bearer) on `:9878` for the phone. Every event is a JSON line in `<out>/events.jsonl`; `report` prints the latency table. |
| `iOS/CueProtoApp.swift` | Asks for notification permission, registers the shipping `approval` / `question` categories (same identifiers and foreground options), creates two `CKQuerySubscription`s (`kind == approval` / `question`, creation only, generic alert text, `collapseIDKey = sessionKey`, mutable content), measures the Mac↔phone clock offset, and uploads the delivered-notification list whenever it comes to the foreground. A banner button POSTs to the Mac listener with the bearer and writes an `Action` record. |
| `NSE/NotificationService.swift` | Runs for every push: checks whether the phone is locked (a `.complete`-protected probe file), fetches the record and puts its `encryptedValues["detail"]` into the body, sets `interruptionLevel = .timeSensitive`, hands the content to the system, then writes a `Receipt`. |

## Run

```bash
cd prototypes/cloudkit-cue && xcodegen generate
```

```bash
xcodebuild -project CueProto.xcodeproj -scheme CueProtoMac -configuration Debug -derivedDataPath build -allowProvisioningUpdates build
```

```bash
xcodebuild -project CueProto.xcodeproj -scheme CueProto -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates CUEPROTO_TOKEN=<token> CUEPROTO_MAC_URL=http://<mac-lan-ip>:9878 build
```

Install with `xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/CueProto.app`, open it once, then:

```bash
build/Build/Products/Debug/CueProtoMac.app/Contents/MacOS/CueProtoMac run --out <dir> --count 20 --interval 30 --token <token>
```

```bash
build/Build/Products/Debug/CueProtoMac.app/Contents/MacOS/CueProtoMac report --out <dir>
```

Both apps must be signed into the same Apple Account. The debug builds use the
Development CloudKit environment; a Developer ID export is forced to
Production (see the ticket), which needs the schema deployed first.

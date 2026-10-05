# Phone pairing

Pairing is the owner's explicit, time-limited consent to link an iPhone to this Mac over the LAN. The phone scans a QR (host, port, bearer token) or types those values; the Mac accepts `POST /device` only while the pairing window is open.

## Sub-features

- `pair-window` opens a two-minute registration window from **Pair a phone** or `vibebuddyd --pair`.
- `pair-reject` refuses `POST /device` when the window is closed (`403`).
- `pair-accept` accepts a structured device body while the window is open (`200`) and records the phone.
- `pair-forget` requires a new window before the same phone can register again after forget (production Settings **Forget all phones**).
- `pair-reconnect` lets an already saved phone reconnect later without opening a new window (live app; not this isolated first-registration proof).

## How to get to it (user POV)

- On Mac: menu-bar cat → phone-details popover or Settings → **Pair a phone**. Scan the QR labeled **Pairing QR code** within 2 minutes (`Scan this in the vibebuddy iOS app within 2 minutes.`).
- On iPhone Connect: **Scan to pair**, or **Enter address manually** (Host / Port / Token) then **Connect**.
- Headless: `vibebuddyd --pair` prints `Pairing enabled for 120 seconds.`
- Tailscale: in **Devices & connection** choose **Away from Mac**; the `100.x.x.x` address is detected (or typed under **Advanced connection settings**), then **Show connection code** pairs to that address (still the same token and port).

## Driving it with control-vibebuddy

Preconditions:

- First prove the closed window, then the open window. Use two launches or launch with `--pair` only for the accept step.
- Isolated port is not `9876`.
- `doctor` passes for whichever instance you are driving.
- Do not screenshot the token or QR payload.

- **Closed window.** Launch without pairing. Run `control-vibebuddy launch` then `control-vibebuddy doctor`. Register a phone. Run `code=$(control-vibebuddy device --name 'Verify Phone' --device-id 'verify-phone-1' | tail -n 1)`. The last line is `403`.
- **Proof of reject.** Run `control-vibebuddy evidence --label phone-pairing-rejected`. `meta.txt` records the run. There is no new paired entry in `device-registry.json` (file missing or entries empty).
- **Cleanup the reject instance.** Run `control-vibebuddy cleanup`. Confirm the reject evidence directory still exists.
- **Open window.** Launch with pairing. Run `control-vibebuddy launch --pair` then `control-vibebuddy doctor`. Daemon log contains `Pairing enabled for 120 seconds.`
- **Accept.** Register inside two minutes. Run `code=$(control-vibebuddy device --name 'Verify Phone' --device-id 'verify-phone-1' | tail -n 1)`. The last line is `200`.
- **Confirm persistence.** Run `control-vibebuddy evidence --label phone-pairing`. `device-registry.json` includes `verify-phone-1` / `Verify Phone`.
- **iPhone UI entry (Mac + simulator only).** Point a simulator at this isolated host/port/token via `SIMCTL_CHILD_VIBEBUDDY_HOST` / `PORT` / `TOKEN` and use **Scan to pair** or manual **Connect**. A connected dashboard title is the Mac name, not `Demo`. If simctl is missing, record `verified-unreachable` for this entry only; the HTTP accept/reject still stands.

## Gotchas

- The window is **120 seconds**. If `POST /device` is `403` after `--pair`, the window expired — relaunch with `--pair`, do not retry against a stale process.
- Saved pairing is not proof the phone is online or that push works (`GLOSSARY.md` Pairing / Push coverage).
- `POST /device` is token-gated. A 401 is a wrong bearer, not a closed window.
- Historical registrations without recorded consent show as **registered**, not **paired**, in Settings.
- `scripts/phone_qa_harness.sh` defaults to `:9876` and the login token file. Do not point it at production during this skill.
- Never commit or paste the run token, QR JSON, or Tailscale host from a real machine.

## Switching an existing pairing between LAN and tailnet

Both Mac methods offer **Send selected address to iPhone**. The picker only
selects a candidate; it does not change the phone's saved route. Keep the old
route reachable and the phone app active until the check finishes. If the old
route is unavailable, or an older phone build ignores LAN proposals, scan a
new code. Close an open code before changing methods.

Focused regression commands:

```bash
swift test --package-path VibeBuddyKit --filter CompanionEndpointTests
swift test --package-path VibeBuddyMac --filter RemoteConnectionSyncTests
# With an available iOS runtime/device, run VibeBuddyAppTests/RemoteConnectionSyncTests.
```

Acceptance: on an isolated Mac app, register a disposable phone, select LAN,
send the address, and verify the proposal via authenticated `/connection-sync`.
Check the waiting, unreachable and confirmed UI. LAN confirmation must keep
Wi-Fi on; tailnet confirmation retains the cellular verification instruction.
Replayed/emulated receipts only prove the Mac path, not the phone's save.
On a real phone, switch tailnet → LAN, verify the same Mac's live snapshot,
then exercise an unreachable candidate and confirm the saved pairing survives.

## Acceptance evidence — 2026-10-01

LAN proposal regression failed before the change and passed after it. Kit
address tests (7), Mac sync tests (3, including both route arguments), Mac/iOS
builds and iOS test compilation passed. Initial isolated Mac UI checks on
18793 used emulated receipts; the real-device results below supersede them.

A separately signed iPhone QA app and isolated Mac QA on 18794 preserved
production apps and pairing. Temporary copies disable phone CloudKit/shared
widget integration and allow both Mac interfaces; connection validation,
persistence and receipts use the changed product code. On the real iPhone,
10 focused tests and two live LAN tests passed, covering authenticated HTTP,
WebSocket delivery of this chat's real Codex session and wrong-token rejection.
QA assets/results are in `.scratch/connection-real-e2e/` and local Xcode test
results; disposable credentials there must not be committed.

Computer Use with iPhone Mirroring completed the following at 13:41–13:43:

- LAN → Headscale → LAN → Headscale: every send reached real phone validation
  and Mac `iPhone checked and saved`; app-container preferences matched each
  candidate. No emulated receipts were used for these checks.
- The phone showed `已连接` on LAN and `远程已连接` on tailnet, with one real
  Codex session and the iOS-vibebuddy project. Restart without host/token
  environment overrides restored the tailnet connection and same live data.
  LAN restart had also passed during diagnosis.
- Before gateway repair, a real tailnet proposal reached received/checking →
  unreachable. The phone retained its LAN pairing and continued connected.
  Replay by making only the candidate unreachable, sending from the working
  old route, then checking the failure receipt, saved address and live data.
- Same-network guidance now names Tailscale, Headscale and Surge; running QA
  AX verified the text. QR lock explanation and method-selection semantics
  were also checked. Mirror errors recovered and were not product failures.

This proves switching over the home's Surge gateway. Cellular/away-from-home
reachability was not tested. Production app binaries were not replaced;
changes remain uncommitted. CONN-01 was closed after the real-device checks,
following the repository's completed-ticket deletion convention.

### Gateway failure and authorized repair

Janus system routing reached the QA health endpoint; Surge Home Tailnet timed
out. Its automatic peer-address override outranked ordinary/temporary rules.
See [Surge Tailscale routing](https://manual.nssurge.com/policies/tailscale.html).
With explicit owner approval, Atlas retained existing IPv4/IPv6 tailnet and
MagicDNS rules, disabled `auto-add-magic-dns-rule`, and added only the target
Mac's /32 DIRECT rule. DIRECT uses Janus's system Tailscale tunnel. This avoids
the failed Surge internal path; its underlying tunnel failure is not resolved.
The tradeoff is that future peer routing depends on the retained explicit rules.

Candidate validation and concurrent-change comparison preceded atomic write
and auto-reload. Default-policy HEAD probe changed from timeout to a server
404 in about 22 ms (HEAD unsupported; this alone is not a health success).
Other tailnet/MagicDNS rule matching stayed unchanged. Temporary rules were
removed. The subsequent real-phone checks establish application success.

The original remains on Janus under Surge Profiles:
`.network-profiles-backups/Atlas.CONN-01.20261001-123410.before.conf`.
It contains credentials: do not copy or commit. Roll back only the added
DIRECT exception and automatic-rule setting after checking current changes;
do not overwrite later edits with the whole backup.

UX: send a selected address without discarding pairing; failed checks preserve
the working route. DX: reuse proposal/check/save/receipt and narrowly validate
private IPv4 addresses. AX: this record separates simulated tests, real-device
proof, gateway changes and the untested cellular path.

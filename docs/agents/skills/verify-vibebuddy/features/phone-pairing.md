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
- Tailscale: enable **Use Tailscale for remote access**, paste the tailnet host, then pair to that address (still the same token and port).

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
- Saved pairing is not proof the phone is online or that push works (`CONTEXT.md` Pairing / Push coverage).
- `POST /device` is token-gated. A 401 is a wrong bearer, not a closed window.
- Historical registrations without recorded consent show as **registered**, not **paired**, in Settings.
- `scripts/phone_qa_harness.sh` defaults to `:9876` and the login token file. Do not point it at production during this skill.
- Never commit or paste the run token, QR JSON, or Tailscale host from a real machine.

# Mac and iPhone connection center

**Status:** Accepted (2026-09-15), owner selected Mac prototypes A + C and iOS A.

## Decision

Mac Settings uses **Devices & connection** with **Same Wi-Fi** and **Away from Mac**. The menu-bar footer has a labelled **Connect iPhone** entry opening the same connection controls in a compact popover. It links directly to the full settings page. A shared native view owns both presentations.

Active local IPv4 interfaces supply candidate tailnet addresses. A single detected address fills an empty field; multiple addresses require a choice. A saved address is retained. The user can enter an IPv4 address manually. Address detection does not establish Headscale membership or phone reachability.

**Show connection code** opens the existing explicit 120-second pairing window. PairingPayload remains a single host, port, token and optional Mac name. Scanning and saved registration do not prove current remote reachability. iPhone validates authenticated real-time state before replacing its pairing.

For an already confirmed phone, **Sync to iPhone** publishes a five-minute, device-bound RemoteConnectionProposal. It contains requestID, sourceID, deviceID, host, port and expiry; it does not contain a bearer token. Only a confirmed registered device, authenticated with the existing header bearer, may poll `GET /connection-sync?deviceID=...` and report `POST /connection-sync/receipt`. It uses the existing trust boundary in ADR-0009, with no public listener or separate cloud service.

iPhone polls while active, uses its saved bearer against the candidate address, validates the returned snapshot sourceID, rechecks that the proposal is still current, then saves and reports `confirmed`. Cancelling sync on Mac removes the proposal and invalidates in-flight work, as do a different pairing, expiry or a superseding proposal. Received, unreachable, unauthorized and cancelled outcomes never claim a saved connection. Failed candidates can be retried explicitly on the phone before expiry; the same request may advance to confirmed, but received cannot overwrite a failure and no outcome may downgrade confirmed. A repeated received receipt for a still-valid failed or paused request is accepted without changing its outcome or timestamp, so a restarted iPhone can resume verification. Repeated confirmed receipts are idempotent. The phone retries undelivered confirmation separately from reapplying settings.

The iPhone `cancelled` receipt means the active check was interrupted, including when the app enters the background. It is presented as a paused check, not a user rejection. The current iPhone process requires an explicit retry after a failed or interrupted check. A new iPhone process may resume a still-authorized, unexpired proposal, and must repeat the sourceID and current-proposal checks before saving. There is no phone-side reject action or persistent rejection record. A Mac withdrawal remains effective across phone restarts.

Transfers are in memory and disappear at daemon restart. Forgetting phones cancels pending transfers. Starting a new transfer for the same device replaces the old request, so late receipts return conflict. An offline phone is shown as waiting for receipt, not successfully configured. Old clients do not poll the optional endpoints and continue pairing with QR codes.

## Boundaries

Surge/Tailscale login remains in the network app. A copied Surge interactive-login configuration does not carry its locally stored identity. Mac must support inbound connections; Surge's outbound policy alone does not do so. The UI links to Headscale's Apple setup instructions.

A successful private-address check proves the current path, not cellular access. The completion copy asks the owner to turn off Wi-Fi and check again. Reverse scanning (Mac camera scans iPhone), multiple addresses in PairingPayload, and automatic Headscale enrollment were not selected.

## Amendment — LAN return path (2026-10-01)

The existing authenticated handoff also accepts RFC1918 IPv4 destinations,
so **Same Wi-Fi** and **Away from Mac** share the same send/check/save flow.
The schema and endpoint names remain unchanged. Public, loopback, link-local
and DNS destinations are not accepted for handoff. Manual remote setup keeps
its tailnet-only validation. All sourceID, device, expiry, cancellation and
receipt checks remain in force; a failed check preserves the old pairing.

The method picker selects the address to send, not the phone's live route.
Opening a QR locks the picker until the code is closed, with an inline reason.
Saved pairing is not presented as proof of a live connection. Confirmation
copy describes the proposal's address, even if the picker has since changed.
LAN confirmation never asks the user to disable Wi-Fi.

Sending requires a working existing phone connection. If it is unavailable,
or the installed phone version does not support LAN handoff, scan a new code.
No automatic route fallback or new pairing authority is introduced.

## Amendment — Optional Cloudflare Access path (2026-10-01)

An already-paired iPhone may save one Cloudflare HTTPS origin alongside its
verified direct connection. It explicitly selects a path; there is no automatic
routing or simultaneous connection. The original QR authorization remains in
place. A new candidate must return an authenticated snapshot with the original
Mac sourceID before replacing the active path; cancellation and failure retain
the previous connection. Private-address handoffs never inherit Access credentials.

The dedicated origin uses HTTPS/WSS on port 443. Access Service Auth checks
per-device service credentials, and the daemon still checks its existing bearer
(ADR-0009). Only local credential references appear in connection settings;
Access secrets live in the iPhone Keychain and do not enter QR payloads, Watch
relay data, logs or URLs. Authenticated requests refuse redirects. Existing Mac
bearer storage is unchanged; migrating old credentials is separate work.

The Mac connection center adds a configuration guide. Official cloudflared owns
the Tunnel; VibeBuddy does not manage its process, accounts, DNS or token issuance.
The local service is not proof of remote connectivity. The iPhone verifies the
actual WebSocket and existing actions; production acceptance includes cellular
use, reconnect and rejection of a revoked token on a new connection.

This adds no VibeBuddy-operated relay, no Kairos dependency, and no changes to
APNs/CloudKit or the action-delivery contracts in ADR-0032/0033.

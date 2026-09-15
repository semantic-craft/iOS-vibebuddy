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

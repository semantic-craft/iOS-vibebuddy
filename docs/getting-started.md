# Getting started with VibeBuddy

VibeBuddy's Mac app tracks Claude Code, Codex and Grok Build tasks, optionally
observes Grok Bot, and reads Cursor account usage. Add the iPhone and Apple Watch
companions to bring those views with you. [Back to the homepage](../README.md).

## Install and pair

1. Download the DMG from [GitHub Releases](https://github.com/semantic-craft/iOS-vibebuddy/releases/latest).
   The distributed Mac build requires Apple Silicon and macOS 14 or later.
2. Drag the app into Applications and open it. The menu-bar cat opens the
   activity feed; Dashboard and Settings are available from its footer.
3. Install [VibeBuddy: Agent Monitor for iPhone](https://apps.apple.com/us/app/vibebuddy-agent-monitor/id6777469338)
   where available. iOS 17+ is required. The current Watch companion requires a
   paired iPhone and watchOS 26.5+.
4. Put Mac and iPhone on the same trusted local network. Choose **Pair a phone**
   on Mac, then **Scan to pair** on iPhone. New phone registration is allowed for
   two minutes; open the pairing window again if it expires.

Keep the Mac running and reachable for live tasks and actions. Existing paired
phones reconnect without opening a new pairing window. The Mac can be used
alone; iPhone Demo mode can be explored without pairing.

The local connection uses HTTP/WebSocket with bearer authentication, not built-in
TLS. Use a trusted LAN or a protected private network; do not expose port 9876
directly to the public internet. Treat the pairing QR as a credential.

## Remote access with Tailscale

Use the official Tailscale apps on your Mac and iPhone and sign both into the
same tailnet. VibeBuddy does not install, log in to or manage the VPN. No
Cloudflare account, public domain or router port forwarding is needed.

1. In Tailscale on the Mac, copy its IPv4 address (`100.x.x.x`) or full MagicDNS
   name (`your-mac.your-tailnet.ts.net`).
2. Open VibeBuddy's phone details on the Mac, enable **Use Tailscale for remote
   access**, and paste that address without a URL scheme, path or port.
3. Choose **Pair a phone** to open the two-minute pairing window. Scan the QR on
   iPhone, or use manual entry with the same host, the Mac service port (normally
   `9876`), and pairing token. Keep the QR and token private.
4. With Tailscale connected on iPhone, turn off Wi-Fi and check that a current
   task appears. Test a supported action and check its receipt; saving an address
   alone does not establish a connection.

Existing LAN pairings remain unchanged. To return to LAN, select that connection
on the Mac and pair using its LAN address. There is one selected connection, with
no automatic fallback between addresses. The app uses HTTP/WS inside Tailscale's
protected network; it does not expose the daemon publicly or add HTTPS support.
MagicDNS requires Tailscale DNS resolution; the app permits HTTP to `*.ts.net`
for this private-network flow, without disabling transport security globally.

If access is refused, check the pairing token and explicitly reconnect. If a
connection times out, check both Tailscale clients, the Mac's running state and
whether tailnet rules permit the service port. A timeout does not identify which
of these failed. The app reconnects after ordinary network interruptions but
never resends an uncertain task action automatically.

Apple Watch continues to use the paired iPhone connection; this does not enable
independent Watch networking. Background notifications still need the separate
APNs setup below. The Mac must remain running and reachable. Other VPNs on iPhone
may conflict with Tailscale; see the official [VPN compatibility notes](https://tailscale.com/docs/reference/faq/other-vpns)
and [MagicDNS guide](https://tailscale.com/docs/features/magicdns).

## Connect an agent

Start with Setup in the Mac app's settings. For manual installation, clone this
repository and run the appropriate installer from its root while VibeBuddy is
running. Python 3 and the agent CLI are required.

### Claude Code

```bash
python3 hooks/install-claude-hooks.py --dry-run
python3 hooks/install-claude-hooks.py --install
```

To enable supported permission decisions and question replies, also run:

```bash
python3 hooks/install-claude-hooks.py --approval
```

Start a fresh Claude Code session and submit a short task. When a supported
permission or question arrives, VibeBuddy shows its available controls. If the
request belongs to the native Mac prompt, the companion directs you there.

### Codex

```bash
python3 hooks/install-codex-hooks.py --install
python3 hooks/install-codex-hooks.py --approval
```

In a fresh Codex CLI session, review and trust the installed hooks through
`/hooks`. The approval option is needed only for remote permission decisions.
Follow the Mac setup instructions for the app-server connection used by task
creation, continuation and steering.

Codex Desktop can run a separate app-server. Local task observation does not
establish permission coverage or task-control access. Read the
[Codex integration contract](codex-integration.md) for the current boundary and
[probe instructions](../tools/codex-integration/README.md) for diagnostics.

### Grok Build

```bash
python3 hooks/install-grok-hooks.py --dry-run
python3 hooks/install-grok-hooks.py --install
```

Reload Grok's hooks with `/hooks` then `r`, or start a fresh session. The optional
`--approval` installer flag adds the blocking approval gate. Grok's permission
mode determines whether a phone approval also resolves the native prompt; read
the [Grok Build setup details](multi-cli-hook-setup.md#grok-build-grokhooksvibebuddyjson)
before enabling it. Task observation and account usage do not require that gate.

### Grok Bot

Sign in through the official Grok Bot app, then enable **Observe Grok Bot tasks**
in VibeBuddy's Mac settings. The observer is off by default. Its read-only view
supports task status, verified ordinary completions and optional completion
summaries/read-aloud; replies and approvals stay in Grok Bot. Question
continuations, automated tasks and turns spanning a disconnect are not yet
supported, so check those results in the official app.

For its separate quota, use the **Grok Bot** section in Usage settings. If access
is needed, use **Authorize Grok Bot account access…** there, then enable collection
and refresh. Renew expired login in Grok Bot itself.

### Cursor

In Mac **Settings → Usage → Login source**, choose the existing Cursor app or
**Cursor CLI login**. The CLI path uses the account signed in through
`cursor-agent login` and does not require the Cursor desktop app. Refresh usage
to see **Cursor Models** and **Other Models** as separate pools. Available values
depend on the selected account and provider response. This is account-usage
integration; Cursor task tracking and remote approval are not yet supported.

### Experimental adapters and removal

See [multi-agent hook setup](multi-cli-hook-setup.md) for experimental adapters.
The Claude, Codex and Grok installers accept `--uninstall` to remove managed entries.
Keep this checkout at its installed path while file-based hooks refer to it.

## Optional AI and notifications

Voice conversation, completion summaries and Mac read-aloud each have their own
settings. Add your provider credential in the app's native settings, select the
feature's provider/model, and use the connection or voice preview controls. These
configuration checks do not replace trying an actual call. Monitoring and button
approvals work without AI credentials.

Closed-app push is a separate setup: the Mac needs APNs credentials matching the
iPhone app's signing team, bundle and environment. Public downloads do not yet
provide a turnkey path. Do not use a different team's APNs key with the App Store
binary. See [APNs setup](apns-setup.md) and the
[distribution decision](adr/0013-apns-key-delivery.md).

## Build from source

Use **Xcode 26.6**, **Swift 6** and **XcodeGen** for the current project. App
deployment targets are macOS 14, iOS 17 and watchOS 26.5. Package minimums may be
lower than app minimums. Install XcodeGen with `brew install xcodegen` if needed.

```bash
git clone https://github.com/semantic-craft/iOS-vibebuddy.git
cd iOS-vibebuddy
```

Generate and open the Mac project from the repository root:

```bash
xcodegen generate --spec VibeBuddyMacApp/project.yml
open VibeBuddyMacApp/VibeBuddyMacApp.xcodeproj
```

Choose the `VibeBuddyMacApp` scheme, select your signing team if needed, then
build and run. For iPhone and Watch:

```bash
xcodegen generate --spec VibeBuddyApp/project.yml
open VibeBuddyApp/VibeBuddyApp.xcodeproj
```

Choose the `VibeBuddyApp` scheme and a simulator or your device. For a device
build, select your own signing team and unique bundle identifiers for the app
and its extensions; configure capabilities for that team. Release scripts are
maintainer tooling and are not required for a local build.

The headless Mac daemon is an alternative to the menu-bar app. Run one server
at a time on the default port:

```bash
swift run --package-path VibeBuddyMac vibebuddyd --pair
```

`--pair` opens the same two-minute registration window. Use the daemon's pairing
instructions; never share its token in an issue or screenshot.

## Check a change

For shared logic or server changes, the existing package tests are:

```bash
swift test --package-path VibeBuddyKit
swift test --package-path VibeBuddyMac
```

For app behavior, build the affected app and exercise that flow with actual agent
data. Record whether the check used Demo mode, a simulator, an isolated Mac app or
physical devices. Documentation-only changes need link and rendering checks, not
an app build. See [contributing](../CONTRIBUTING.md).

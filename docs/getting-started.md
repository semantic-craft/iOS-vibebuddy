# Getting started with VibeBuddy

VibeBuddy's Mac app tracks Claude Code, Codex and Grok Build tasks, and reads
Cursor and Grok Bot account usage. Add the iPhone and Apple Watch
companions to bring those views with you. [Back to the homepage](../README.md).

## Install and pair

1. Download the DMG from [GitHub Releases](https://github.com/semantic-craft/iOS-vibebuddy/releases/latest).
   The distributed Mac build requires Apple Silicon and macOS 14 or later.
2. Drag the app into Applications and open it. The menu-bar cat opens the
   activity feed; Dashboard and Settings are available from its footer.
3. Install [VibeBuddy: Agent Monitor for iPhone](https://apps.apple.com/us/app/vibebuddy-agent-monitor/id6777469338)
   where available. iOS 17+ is required. The current Watch companion requires a
   paired iPhone and watchOS 26.5+.
4. Put Mac and iPhone on the same trusted local network. Choose **Show
   connection code** on Mac, then **Scan to pair** on iPhone. New phone
   registration is allowed for two minutes; open the pairing window again if it
   expires.

Either order works. Until a phone has paired, the Mac's Inbox shows a **Get
started** checklist (hook agents, an App Store QR code for the iPhone app, the
pairing code), and the same App Store card sits in **Settings → Devices &
connection**. The iPhone's first screen walks the other way: **Send link to my
Mac** hands the Mac download to AirDrop, Notes or Mail, then **Scan to pair**.

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

### Headscale with Surge on iPhone

The iPhone can use **Surge's built-in Tailscale policy** to join Headscale;
it does not need a second active VPN. In Surge's policy editor, configure a
Tailscale policy with your Headscale `control-url`, authorize it, and ensure
traffic to the Mac's private IPv4 address selects that policy. Consult the
[Surge Tailscale guide](https://manual.nssurge.com/policies/tailscale.html)
for version requirements, sign-in and routing options.

The **receiving Mac needs the system Tailscale client**, connected to the same
Headscale server with incoming connections allowed. Its Surge proxy can keep
running. Surge's Tailscale policy handles outbound connections only and does
not expose services on the Mac. Use the system client's IP, not the Surge
node's IP. See [Headscale's Apple setup](https://headscale.net/stable/usage/connect/apple/).
The private network ACL and Mac firewall must permit the VibeBuddy service port.

After pairing, on iPhone open **Settings → Connect your Mac → Headscale & Surge**.
Enter the Mac's `100.64.0.0/10` IPv4 address and service port, then choose
**Test and use this address**. The phone uses its saved pairing bearer to request
a live WebSocket snapshot. Only success saves the replacement address; failure
or leaving the screen keeps the current pairing. This checks the app's data
path, not just whether the VPN says connected. Custom Headscale DNS suffixes
are not covered by the app's HTTP domain exceptions, so use the private IPv4
address here. The Headscale control-server URL is never the VibeBuddy address.

For acceptance, disable iPhone Wi-Fi while keeping Surge on. Open VibeBuddy,
verify a real running task changes, and check the same task and update time on
the paired Watch. Repeat after a network interruption. A local simulator test
does not establish cellular reachability. The Watch gets snapshots through
the iPhone; iOS suspension can leave an older snapshot visible, and background
alerts still depend on APNs. This setup does not keep the iPhone process alive
indefinitely or give the Watch an independent VPN.

## Connect an agent to local history

In the Mac app, open **Settings → Connect**. Copy the bundled executable path or
the configuration for Claude Code, Codex or Cursor. The path refers to this app's
`Contents/MacOS/vibebuddy-mcp`; keep the app at that location while clients use it.
No alias, separate installation or running Mac app is required for history queries.

Run the copied executable path with `setup` to print the same client snippets and
an optional rule for `AGENTS.md`. Setup only prints instructions. With no index it
prints a `Note:` and exits successfully. Open **History** in the Mac app to build
the local index, or explicitly run the executable with `index` (`index --rebuild`
refreshes an existing index). Queries never refresh the index themselves.

- **Claude Code:** run the copied `claude mcp add --scope project --transport stdio`
  command in your project. Approve the project server in Claude Code, then check
  `claude mcp list` and ask it to call `vibebuddy_list_sessions` for this checkout.
- **Codex:** merge the copied `[mcp_servers.vibebuddy]` section into
  `~/.codex/config.toml`, preserving other sections. Restart your session and check
  that the six `vibebuddy_*` tools appear before making a history query.
- **Cursor:** merge the copied `vibebuddy` object into `mcpServers` in
  `~/.cursor/mcp.json`, preserving existing servers. Reload Cursor, enable the
  server in its MCP settings, and verify a connected state and an actual tool call.

Configuration formats: [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp#configure-with-configtoml)
and [Cursor MCP](https://prod.cursor.com/docs/mcp#stdio-server-configuration).
The Copy buttons do not edit client configuration or authenticate to a provider.

With no arguments, `vibebuddy-mcp` serves stdio MCP. Its six read-only CLI queries
are `sessions`, `projects`, `search QUERY`, `show KEY|REF`, `summary KEY|REF`, and
`status`. `call TOOL JSON` reaches the same tool layer. Transcript references use
`vibebuddy://session/<agent>:<native-id>#<seq>`. Listings state index freshness;
saved summaries state coverage and staleness, and are never generated by MCP.
Cursor local transcripts lack tool results and thinking; Grok Build currently
provides only a session list and titles, without full-text search or summaries
generated from that source. See [source coverage](session-history.md).

`status` optionally reads the local daemon's snapshot. A stopped or unreachable
daemon returns **live status unknown**; history remains available. Full checkout
paths for Desktop sessions require a daemon built with that support; older daemons
may show unknown checkouts. Connecting MCP never starts or replaces your daemon.
`show` can read an available native transcript without an index; indexed listing
and search need the index. The explicit `index` command is the only CLI maintenance
exception: there are no approval, answer, stop, dispatch or library-write tools.

## Connect an agent for live observation

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

Grok Bot is an account-usage source only — VibeBuddy shows its remaining
allowance and nothing else. Tasks, replies and approvals all stay in the
official app.

Sign in through the official Grok Bot app, then use the **Grok Bot** section in
Usage settings. If access is needed, use **Authorize Grok Bot account access…**
there, then enable collection and refresh. Renew expired login in Grok Bot
itself.

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

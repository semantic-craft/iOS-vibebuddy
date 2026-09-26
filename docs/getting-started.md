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

Official Tailscale on both devices is all you need. Sign the Mac and the iPhone
into the same tailnet; VibeBuddy does not install, log in to or manage the VPN.
No Cloudflare account, public domain or router port forwarding is needed.

1. **Mac:** install [Tailscale for Mac](https://tailscale.com/download/mac) and
   sign in. The App Store, standalone and Homebrew clients all work, since
   VibeBuddy only needs the Mac's tailnet address and incoming connections to
   its service port. For a Mac that stays on unattended, prefer the Homebrew
   client registered with `sudo brew services start tailscale`: it runs as a
   system daemon and reconnects at boot without anyone opening an app.
2. In VibeBuddy on the Mac, open **Devices & connection** and choose **Away
   from Mac**. VibeBuddy reads the Mac's `100.x.x.x` address from its network
   interfaces; enter it under **Advanced connection settings** only if it is
   not detected.
3. **iPhone:** install [Tailscale](https://apps.apple.com/app/tailscale/id1470499037)
   and sign in with the same account. Keep it connected.
4. On the Mac, choose **Show connection code**. On iPhone, open **Connect away
   from home** (from the first screen, or **Settings → Device & connection**),
   scan the code and choose **Check and save**. The phone saves the address
   only after it receives live status from the Mac over that address. Step 2
   of that page shows whether this iPhone currently has a tailnet address.
5. For acceptance, turn off Wi-Fi with Tailscale still connected and check
   that a current task appears. Test a supported action and check its receipt;
   saving an address alone does not establish a connection.

Use the Mac's `100.x.x.x` IPv4 address. MagicDNS names are not accepted in
the pairing screens, and a Headscale control-server URL is never the
VibeBuddy address. Existing LAN pairings remain unchanged; to return to LAN,
choose **Same Wi-Fi** on the Mac and pair again. There is one selected
connection, with no automatic fallback between addresses. The app uses
HTTP/WS inside the private network; it does not expose the daemon publicly or
add HTTPS support.

If access is refused, scan the Mac's current code again. If a connection
times out, check both Tailscale clients, whether the Mac is awake with
VibeBuddy running, and whether tailnet rules permit the service port. A
timeout does not identify which of these failed. The app reconnects after
ordinary network interruptions but never resends an uncertain task action
automatically.

Apple Watch continues to use the paired iPhone connection; this does not enable
independent Watch networking. Background notifications still need the separate
APNs setup below. The Mac must remain running and reachable. iOS runs one VPN
at a time, so Tailscale and another VPN app cannot both be active; see the
official [VPN compatibility notes](https://tailscale.com/docs/reference/faq/other-vpns).

### Variant: self-hosted Headscale

Everything above applies. In the Tailscale apps on the Mac and the iPhone,
choose your own control server before signing in; see
[Headscale's Apple setup](https://headscale.net/stable/usage/connect/apple/).
The Headscale ACL and the Mac firewall must permit the VibeBuddy service port.

### Variant: Surge on iPhone

If the iPhone already routes through Surge, it can join the tailnet with
**Surge's built-in Tailscale policy** instead of a second VPN. In Surge's
policy editor, configure a Tailscale policy (for Headscale, its
`control-url`), sign in, and make sure traffic to the Mac's `100.x.x.x`
address selects that policy. See the
[Surge Tailscale guide](https://manual.nssurge.com/policies/tailscale.html).
When both Surge and Tailscale are installed, **Connect away from home** lets
you choose which one you use, and **Turn on Tailscale or Surge** opens that
one.

The **Mac still needs a Tailscale client**, connected to the same tailnet with
incoming connections allowed. Surge on the Mac can keep running, but its
Tailscale policy handles outbound connections only and cannot receive
connections to the Mac. Use the Mac's Tailscale client address, not a Surge
node's address.

## Connect an agent to handoff facts and transcripts

In the Mac app, open **Settings → Connect**. Copy the bundled executable path or
the configuration for Claude Code, Codex or Cursor. The path refers to this app's
`Contents/MacOS/vibebuddy-mcp`; keep the app at that location while clients use it.
No alias or separate installation is required.

Run the copied executable path with `setup` to print the same client snippets and
an optional rule for `AGENTS.md`. Setup only prints instructions.

- **Claude Code:** run the copied `claude mcp add --scope project --transport stdio`
  command in your project. Approve the project server in Claude Code, then check
  `claude mcp list` and ask it to call `vibebuddy_live_status` for this checkout.
- **Codex:** merge the copied `[mcp_servers.vibebuddy]` section into
  `~/.codex/config.toml`, preserving other sections. Restart your session and check
  that the three `vibebuddy_*` tools appear.
- **Cursor:** merge the copied `vibebuddy` object into `mcpServers` in
  `~/.cursor/mcp.json`, preserving existing servers. Reload Cursor, enable the
  server in its MCP settings, and verify a connected state and an actual tool call.

Configuration formats: [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp#configure-with-configtoml)
and [Cursor MCP](https://prod.cursor.com/docs/mcp#stdio-server-configuration).
The Copy buttons do not edit client configuration or authenticate to a provider.

With no arguments, `vibebuddy-mcp` serves stdio MCP. Its three read-only CLI
queries are `facts KEY|REF` (what the Mac recorded for one session: rounds, git
state, edited files, commands), `show KEY|REF` (that session's transcript, read
straight from the agent's own file) and `status` (current sessions per checkout).
`call TOOL JSON` reaches the same tool layer. Transcript references use
`vibebuddy://session/<agent>:<native-id>#<seq>`. There is no archive, index or
search of past conversations. Cursor local transcripts lack tool results and
thinking; Grok Build has no readable transcript.

`status` optionally reads the local daemon's snapshot. A stopped or unreachable
daemon returns **live status unknown**. Connecting MCP never starts or replaces
your daemon. There are no approval, answer, stop or dispatch tools.

## Connect an agent for live observation

Start with Setup in the Mac app's settings: **Install / repair** wires every
detected CLI. No Python is needed — the app installs natively, copies the hook
scripts (sh and curl only) to `~/Library/Application Support/vibebuddy/bin/`, and
points each CLI's config at that one path, so app updates never change the
installed commands. **Uninstall** removes only VibeBuddy's entries, restores your
status line, and is remembered: updates never put the hooks back.

Without the menu-bar app, the daemon does the same from a checkout of this
repository:

```bash
cd VibeBuddyMac
swift run vibebuddyd hooks install                    # every detected CLI
swift run vibebuddyd hooks install --agent claude     # one CLI (repeatable)
swift run vibebuddyd hooks status                     # what is installed where
swift run vibebuddyd hooks uninstall                  # remove everything
```

The scripts are taken from the installed app when there is one, else from this
checkout's `hooks/` (`--hooks-dir ../hooks` forces the checkout); the output
names the source.

### Claude Code

```bash
swift run vibebuddyd hooks install --agent claude
```

To enable supported permission decisions and question replies, add `--approval`:

```bash
swift run vibebuddyd hooks install --agent claude --approval
```

Start a fresh Claude Code session and submit a short task. When a supported
permission or question arrives, VibeBuddy shows its available controls. If the
request belongs to the native Mac prompt, the companion directs you there.

### Codex

```bash
swift run vibebuddyd hooks install --agent codex
swift run vibebuddyd hooks install --agent codex --approval
```

In a fresh Codex CLI session, review and trust the installed hooks through
`/hooks`. Codex keys that trust to each hook's command, which stays the same
across app updates, so it is needed once (and once more when an older install
is migrated to the stable path). The approval option is needed only for remote permission decisions.
Follow the Mac setup instructions for the app-server connection used by task
creation, continuation and steering.

Codex Desktop can run a separate app-server. Local task observation does not
establish permission coverage or task-control access. Read the
[Codex integration contract](codex-integration.md) for the current boundary and
[probe instructions](../tools/codex-integration/README.md) for diagnostics.

### Grok Build

```bash
swift run vibebuddyd hooks install --agent grok
```

Reload Grok's hooks with `/hooks` then `r`, or start a fresh session. The optional
`--approval` flag adds the blocking approval gate. Grok's permission
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
`vibebuddyd hooks uninstall` (or Settings → Uninstall) removes managed entries.
Installed hooks name the stable copy in `~/Library/Application Support/vibebuddy/bin/`,
not this checkout, so the checkout can move once the hooks are installed.

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

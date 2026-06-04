# vibebuddy iOS — App Store listing copy, privacy policy, reviewer notes

Drafts for App Store Connect. English. Edit freely.

---

## Listing metadata

**Name:** vibebuddy
**Subtitle (≤30 chars):** Watch your AI coding agents
**Primary category:** Developer Tools
**Secondary category:** Utilities

**Promotional text (≤170 chars):**
Keep an eye on your Claude Code and Codex sessions from your phone. Get notified when one needs you, review the exact command, and approve or deny — right from the lock screen.

**Description:**
vibebuddy is the phone companion for the vibebuddy Mac app. It shows the live status of your AI coding agents (Claude Code, Codex) running on your Mac, and lets you respond without walking back to your desk.

• Live dashboard — see every session grouped by Needs Response / Working / Done, with project, branch, model, and context-window usage.
• Status buddy — an at-a-glance mood indicator for everything that's running.
• Remote approvals — when an agent asks to run a command or edit a file, review the full command or diff on your phone and approve or deny.
• Notifications & Live Activity — get a banner the moment a session needs you; track counts on the lock screen and Dynamic Island.

vibebuddy connects directly to your own Mac over your local network (paired by scanning a QR code) — your session data never goes through our servers. The Mac app is free and open source.

Requires the free vibebuddy Mac app running on your Mac, on the same network.

Tip: tap "查看演示 / View Demo" on the connect screen to explore the interface with sample data — no Mac required.

**Keywords (≤100 chars):** claude code,codex,ai agent,terminal,dashboard,approve,coding,developer,remote,monitor

**Support URL:** https://github.com/<you>/vibebuddy   ← replace
**Marketing URL (optional):** same

**What's New (1.0):** First release.

---

## Privacy policy (host this at a public URL — e.g. GitHub Pages)

**vibebuddy — Privacy Policy**
_Last updated: 2026-06-04_

vibebuddy ("the app") is a companion to the vibebuddy Mac application. We designed it to keep your data on your own devices.

**What the app accesses**
- **Local network:** the app connects directly to the vibebuddy Mac app running on your own Mac, over your local network, to display session status and send your approve/deny decisions. This data is exchanged only between your iPhone and your Mac.
- **Camera:** used solely to scan the pairing QR code shown by the Mac app. No images are stored or transmitted.
- **Push notifications:** if you enable notifications, Apple issues a device token that the app sends to your Mac app so it can notify you when a session needs attention. The token is used only for this purpose.

**What we do NOT do**
- We do not operate servers that receive your session data; there is no vibebuddy cloud account.
- We do not collect analytics, advertising identifiers, or location.
- We do not sell or share any data with third parties.
- We do not track you across apps or websites.

**Data retention**
Pairing details (your Mac's address and access token) are stored locally on your device and removed when you disconnect.

**Contact:** <your email>   ← replace

---

## App Privacy nutrition label (App Store Connect answers)
- Data used to track you: **None**.
- Data linked to you: **None**.
- Data not linked to you: **Identifiers — Device ID** (the APNs device token), purpose **App Functionality** only. (Everything else: not collected.)

---

## App Review Information — reviewer notes (paste into the review form)

vibebuddy is the iOS companion to the vibebuddy macOS app (a free, open-source menu-bar tool that monitors local AI coding-agent sessions such as Claude Code and Codex). Normal use pairs the phone to a Mac on the same Wi‑Fi by scanning a QR code.

**Because the review device has no paired Mac, the app includes a built-in Demo mode so you can fully evaluate it without any setup:**
1. Launch the app.
2. On the connect screen, tap **"查看演示(无需 Mac)" / "View Demo"** (below the manual-entry link).
3. The dashboard loads with sample sessions. You can see: the status buddy, the per-session context-window bars, and a sample approval card (an "Edit" diff) — tap **批准 / Approve** or **拒绝 / Deny** to see it resolve.
4. Tap **退出演示 / Exit Demo** (top right) to return.

Camera permission is only for scanning the pairing QR; Local Network permission is only for the direct phone↔Mac connection. No data leaves the user's own devices; there is no backend account.

Demo credentials: none required (Demo mode needs no login).

---

## Production push checklist (Mac side, for when it ships)
- Create an APNs Auth Key (.p8) in the developer portal (one key works for sandbox + production).
- Put `~/Library/Application Support/vibebuddy/apns.json` with `teamID`, `keyID`, `bundleID: com.vibebuddy.app`, `keyPath` (to the .p8), and **`"sandbox": false`** (production endpoint — App Store / TestFlight builds get production device tokens).
- The iOS Release/Archive build already uses `aps-environment = production` (Debug device runs use development).

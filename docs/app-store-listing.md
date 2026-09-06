# vibebuddy iOS — App Store listing copy, privacy policy, reviewer notes

Drafts for App Store Connect. English. Edit freely.

---

## Listing metadata

**Name:** VibeBuddy: Agent Monitor   <!-- "vibebuddy" alone was taken on the store 2026-06-06; bundle id / repo / Mac app stay "vibebuddy" -->
**Subtitle (≤30 chars):** Watch your AI coding agents
**Primary category:** Developer Tools
**Secondary category:** Utilities

**Promotional text (≤170 chars):**
Keep an eye on your Claude Code and Codex sessions from your phone. Get notified when one needs you, review the exact command, and approve or deny.

**Description:**
vibebuddy is the phone companion for the vibebuddy Mac app. It shows the live status of your AI coding agents (Claude Code, Codex) running on your Mac, and lets you respond without walking back to your desk.

• Live dashboard — see every session grouped by Needs Response / Working / Done, with project, branch, model, and context-window usage.
• Status buddy — an at-a-glance mood indicator for everything that's running.
• Remote approvals — when an agent asks to run a command or edit a file, review the command or a bounded diff preview on your phone and approve or deny.
• Notifications & Live Activity — get a banner the moment a session needs you; track counts on the lock screen and Dynamic Island.
• Voice companion (optional) — talk to your agents in real time and approve or answer by voice, using your own AI-provider key. Off by default with an in-app disclosure before first use.

vibebuddy connects directly to your own Mac over your local network (paired by scanning a QR code) — your session data never goes through our servers. The Mac app is free and open source.

Requires the free vibebuddy Mac app running on your Mac, on the same network.

Tip: tap "查看演示 / View Demo" on the connect screen to explore the interface with sample data — no Mac required.

**Keywords (≤100 chars):** claude code,codex,ai agent,terminal,dashboard,approve,coding,developer,remote,monitor

**Support URL:** https://github.com/semantic-craft/iOS-vibebuddy
**Marketing URL (optional):** same

**What's New (1.0):** First release.

---

## Privacy policy (host this at a public URL — e.g. GitHub Pages)

**vibebuddy — Privacy Policy**
_Last updated: 2026-06-05_

vibebuddy ("the app") is a companion to the vibebuddy Mac application. Session connections go directly to your paired Mac; optional push and voice processing use the services described below.

**What the app accesses**
- **Local network:** the app connects directly to the vibebuddy Mac app running on your own Mac, over your local network, to display session status and send your approve/deny decisions. This data is exchanged only between your iPhone and your Mac.
- **Camera:** used solely to scan the pairing QR code shown by the Mac app. No images are stored or transmitted.
- **Push notifications:** if you enable notifications, Apple issues a device token that the app sends to your Mac app so it can notify you when a session needs attention. The token is used only for this purpose. When APNs is configured, your Mac sends notification payloads, including titles and bodies, through Apple's push service to the registered device.
- **Microphone & voice (optional):** the voice companion is **off by default**. It only starts after you choose a provider — OpenAI, Google (Gemini), or Alibaba (DashScope / Qwen) — enter your own provider API key, accept the in-app disclosure, grant microphone permission, and tap again to start a voice conversation. When you use it, your microphone audio and selected session context (project names, agent type, status, and optional summaries) are streamed over an encrypted connection **directly to the provider you choose**, authenticated with **your own key**, which is stored only in your device Keychain. That data is processed by the chosen provider under **their** privacy policy and your account with them; it does **not** pass through any vibebuddy server. The app is fully usable without ever enabling voice.

**What we do NOT do**
- We do not operate servers that receive your voice audio or voice-companion session context; there is no vibebuddy cloud account.
- We do not collect analytics, advertising identifiers, or location.
- We do not sell your data. When enabled, notifications pass through Apple's push service; the optional voice companion sends microphone audio and selected session context directly to your chosen provider with your own key. We operate neither service and receive neither payload.
- We do not track you across apps or websites.

**Data retention**
Pairing details (your Mac's address and access token) are stored locally on your device and removed when you disconnect.

**Contact:** https://github.com/semantic-craft/iOS-vibebuddy/issues

---

## App Privacy nutrition label (App Store Connect answers)
- Data used to track you: **None**.
- Data linked to you: **None**.
- Data not linked to you:
  - **Identifiers — Device ID** (the APNs device token), purpose **App Functionality** only.
  - **Audio Data** — only if you choose to declare the optional voice companion (see the note below). Purpose **App Functionality**, not linked, not for tracking.

**Voice/audio — how to answer the questionnaire (human decision).** The voice companion streams audio **directly to the provider you, the user, configure with your own API key**; vibebuddy operates no server and never receives or stores the audio (ADR-0002). Under Apple's definition, data your app does not access isn't "collected" — so one defensible answer is **not to declare Audio Data at all**. The more conservative, transparent answer — **recommended** — is to declare **Audio Data → App Functionality → Not linked to you → Not used for tracking**, since audio does leave the device. Both are accurate; pick one and be consistent. Do **not** declare any third-party SDK — there is none; it's a direct, user-authorized connection. Either way: no analytics, no advertising, no tracking.

---

## App Review Information — reviewer notes (paste into the review form)

vibebuddy is the iOS companion to the vibebuddy macOS app (a free, open-source menu-bar tool that monitors local AI coding-agent sessions such as Claude Code and Codex). Normal use pairs the phone to a Mac on the same Wi‑Fi by scanning a QR code.

**Because the review device has no paired Mac, the app includes a built-in Demo mode so you can fully evaluate it without any setup:**
1. Launch the app.
2. On the connect screen, tap **"查看演示(无需 Mac)" / "View Demo"** (below the manual-entry link).
3. The dashboard loads with sample sessions. You can see: the status buddy, the per-session context-window bars, and a sample approval card (an "Edit" diff) — tap **批准 / Approve** or **拒绝 / Deny** to see it resolve.
4. Tap **退出演示 / Exit Demo** (top right) to return.

Camera permission is only for scanning the pairing QR; Local Network permission is only for the direct phone↔Mac connection. Session connections go directly to the paired Mac. When APNs is configured, notification payloads (including titles and bodies) pass through Apple's push service; optional voice goes directly to the chosen provider as described below. There is no vibebuddy backend account.

**Time Sensitive notifications.** Only an approval or question that blocks a coding-agent session requests Time Sensitive delivery, and only when its final delivery level includes sound. Quiet downgrades it to an ordinary silent banner; completion, failure, nudge, pairing and quota notices remain ordinary. Category switches and the user's system notification / Focus settings remain effective. Approve requires authentication; read-only waits have no remote action buttons. These are not Critical Alerts. Verify lock-screen, Focus and Watch behavior on real devices before submission; Demo mode does not verify notification delivery. Public closed-app APNs setup remains subject to DEC-APNS (ADR-0013).

**Voice companion (optional).** Tapping the pet can start a real-time voice conversation with the agent companion. It is entirely optional and off by default. It only starts after the user selects a provider (Qwen/DashScope, OpenAI, or Gemini/Google), enters their own provider API key in Settings, accepts the in-app disclosure, grants iOS microphone permission, and taps again to start. When started, the app sends microphone audio plus selected coding-session context (project names, agent type, status, and optional summaries) directly from the device to the selected provider over an encrypted connection using the user's own key. It does not pass through any vibebuddy server. The dashboard, notifications, and approvals are fully usable without voice, so the app can be evaluated end-to-end without setting up a provider key.

Demo credentials: none required (Demo mode needs no login; voice needs no key to review).

---

## Production push checklist (Mac side, for when it ships)
- Create an APNs Auth Key (.p8) in the developer portal (one key works for sandbox + production).
- Put `~/Library/Application Support/vibebuddy/apns.json` with `teamID`, `keyID`, `bundleID: com.vibebuddy.app`, `keyPath` (to the .p8), and **`"sandbox": false`** (production endpoint — App Store / TestFlight builds get production device tokens).
- The iOS Release/Archive build already uses `aps-environment = production` (Debug device runs use development).

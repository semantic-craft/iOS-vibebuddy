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
• Voice companion (optional) — talk to your agents in real time and approve or answer by voice, using your own AI-provider key. Off by default with an in-app disclosure before first use. If the provider's per-call time limit ends a call, one tap starts a fresh one.

vibebuddy connects directly to your own Mac over your local network (paired by scanning a QR code) — your session data never goes through our servers. The Mac app is free and open source.

Requires the free vibebuddy Mac app running on your Mac, on the same network.

Tip: tap "查看演示 / View Demo" on the connect screen to explore the interface with sample data — no Mac required.

**Keywords (≤100 chars):** claude code,codex,ai agent,terminal,dashboard,approve,coding,developer,remote,monitor

**Support URL:** https://github.com/semantic-craft/iOS-vibebuddy
**Marketing URL (optional):** same

**What's New:** the current `docs/release-notes-ios-<version>.md`.

**Age rating:** 4+ ("None" to every questionnaire item). **Availability:** keep the existing 147 regions; China mainland and the 27 EU regions stay unavailable (verified 2026-09-05).

---

## Privacy policy

URL: the published `docs/privacy-policy.md`. Keep that file as the single source; do not paste a copy here.

## App Privacy (App Store Connect answers)

**Live declarations — keep them as they are:** Device ID, Other User Content and Audio Data, each for **App Functionality**, **linked to identity**, not used for tracking. No third-party SDK, analytics or advertising. These match `docs/privacy-policy.md`; change both together or neither.

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

**Voice companion (optional).** Tapping the pet can start a real-time voice conversation with the agent companion. It is entirely optional and off by default. It only starts after the user selects a provider (Qwen/DashScope, Google Gemini, OpenAI, or Doubao/Volcengine), enters their own provider API key in Settings, accepts the in-app disclosure, grants iOS microphone permission, and taps again to start. When started, the app sends microphone audio plus selected coding-session context (project names, agent type, status, and optional summaries) directly from the device to the selected provider over an encrypted connection using the user's own key. It does not pass through any vibebuddy server. The dashboard, notifications, and approvals are fully usable without voice, so the app can be evaluated end-to-end without setting up a provider key.

Demo credentials: none required (Demo mode needs no login; voice needs no key to review).

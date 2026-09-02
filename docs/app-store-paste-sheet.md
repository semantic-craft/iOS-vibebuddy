# App Store Connect — paste sheet (iOS 1.0)

Every field you have to fill in on the web, in the order App Store Connect asks for
it. Copy the fenced blocks verbatim. Source of truth for the wording is
[`app-store-listing.md`](app-store-listing.md); this file is the same text arranged
for typing-free submission. Character limits are Apple's and are already respected.

Legend: **🧑 you only** (login, payment, uploads) · **⚙️ decision** (pick one, then be
consistent) · everything else is copy-paste.

---

## 0. Before the forms — 🧑

| # | What | Where | Done when |
|---|---|---|---|
| 0.1 | Paid Apple Developer Program membership, team `LQAVR62TK2` | developer.apple.com | `tools/archive-ios.sh` produces an Apple Distribution–signed archive |
| 0.2 | Free-app agreement **Active** | App Store Connect ▸ Business (Agreements, Tax, and Banking) | the status reads Active — a submission is impossible until then |
| 0.3 | Privacy policy reachable at a public URL | see §4 | the URL opens in a private window |

---

## 1. New App

App Store Connect ▸ Apps ▸ **+** ▸ New App.

| Field | Value |
|---|---|
| Platform | iOS |
| Name | `VibeBuddy: Agent Monitor` |
| Primary language | English (U.S.) |
| Bundle ID | `com.vibebuddy.app` |
| SKU | `vibebuddy-ios-001` |
| User Access | Full Access |

> The plain name "vibebuddy" was already taken on the store (checked 2026-06-06).
> The bundle id, the repo and the Mac app stay `vibebuddy`; only the store name differs.

---

## 2. App Information

**Subtitle** (≤30 chars — this is 27):

```
Watch your AI coding agents
```

| Field | Value |
|---|---|
| Category — Primary | Developer Tools |
| Category — Secondary | Utilities |
| Content Rights | Does not contain, show, or access third-party content |
| Age Rating | 4+ (answer "None" to every questionnaire item) |

---

## 3. Pricing and Availability

| Field | Value |
|---|---|
| Price | Free |
| Availability | **United States** only |

> **Why not "all countries and regions".** Offering the app in the China mainland
> storefront requires an ICP filing number, and App Store Connect blocks the
> submission without one. Decision of 2026-09-03: US store only, so there is no
> filing obligation and none of what it drags along — no MIIT name matching, so the
> name above keeps its subtitle and stays free to change later.
> `docs/icp-app-filing-checklist.md` is marked not-applicable and holds the detail
> should that ever change.
>
> If you meant "anywhere except China" rather than literally the US, select all
> countries and regions and clear **China mainland** — same filing outcome, far
> wider reach. It is one checkbox either way, and changeable after release.

---

## 4. App Privacy

**Privacy Policy URL** — the text is ready in [`privacy-policy.md`](privacy-policy.md);
it needs a public home first. Publish it to the same GitHub Pages site as the Mac
appcast (`gh-pages` branch of `semantic-craft/iOS-vibebuddy`) and use:

```
https://semantic-craft.github.io/iOS-vibebuddy/privacy-policy.html
```

Data collection answers — "Do you or your third-party partners collect data from
this app?" → **Yes** (the push token counts), then:

| Data type | Collected | Linked to user | Used for tracking | Purpose |
|---|---|---|---|---|
| Identifiers ▸ Device ID (APNs token) | Yes | No | No | App Functionality |
| Audio Data ⚙️ | see below | No | No | App Functionality |
| Everything else | No | — | — | — |

⚙️ **Audio Data — decide once, then keep it consistent.** The voice companion streams
microphone audio straight from the device to the provider *the user* configures with
*their own* API key; vibebuddy runs no server and never receives or stores it
(ADR-0002). Under Apple's definition, data your app does not access is not
"collected", so declaring nothing is defensible. **Recommended: declare it anyway** —
Audio Data ▸ App Functionality ▸ Not linked to you ▸ Not used for tracking — because
audio does leave the device and the conservative answer ages better under review.

Declare **no** third-party SDK: there is none. No analytics, no advertising, no
tracking, no location.

---

## 5. Version Information (1.0)

**Promotional text** (≤170 chars — this is 147, editable after release without review):

```
Keep an eye on your Claude Code and Codex sessions from your phone. Get notified when one needs you, review the exact command, and approve or deny.
```

**Description**:

```
vibebuddy is the phone companion for the vibebuddy Mac app. It shows the live status of your AI coding agents (Claude Code, Codex) running on your Mac, and lets you respond without walking back to your desk.

• Live dashboard — see every session grouped by Needs Response / Working / Done, with project, branch, model, and context-window usage.
• Status buddy — an at-a-glance mood indicator for everything that's running.
• Remote approvals — when an agent asks to run a command or edit a file, review the full command or diff on your phone and approve or deny.
• Notifications & Live Activity — get a banner the moment a session needs you; track counts on the lock screen and Dynamic Island.
• Voice companion (optional) — talk to your agents in real time and approve or answer by voice, using your own AI-provider key. Off by default with an in-app disclosure before first use.

vibebuddy connects directly to your own Mac over your local network (paired by scanning a QR code) — your session data never goes through our servers. The Mac app is free and open source.

Requires the free vibebuddy Mac app running on your Mac, on the same network.

Tip: tap "查看演示 / View Demo" on the connect screen to explore the interface with sample data — no Mac required.
```

**Keywords** (≤100 chars — this is 85, comma-separated, no spaces after commas):

```
claude code,codex,ai agent,terminal,dashboard,approve,coding,developer,remote,monitor
```

**Support URL**:

```
https://github.com/semantic-craft/iOS-vibebuddy
```

**Marketing URL** (optional):

```
https://github.com/semantic-craft/iOS-vibebuddy
```

**Copyright**:

```
2026 Xianwei Zhang
```

**What's New in This Version** — omit for 1.0 (the field only appears from 1.1 on).
If asked anyway:

```
First release.
```

---

## 6. Screenshots — 🧑 upload

Apple requires one set at the largest iPhone size; the rest are scaled automatically.

| Size | File |
|---|---|
| 6.9" (iPhone 16 Pro Max) | `docs/app-store-screenshots/6.9/01-dashboard.png` |
| 6.5" | `docs/app-store-screenshots/6.5/01-dashboard.png` |
| extras | `docs/app-store-screenshots/pro-max-demo-dashboard-resolved.png`, `…-approval-question.png` |

> Only one screenshot per size is committed. Apple accepts a single screenshot, but a
> listing with 3–5 converts better — the two "extras" above are already the right
> device size and can go in as shots 2 and 3.

---

## 7. App Review Information

| Field | Value |
|---|---|
| Sign-in required | **No** |
| Contact | 🧑 your name, phone, email |

**Notes** — this is the field that decides a companion app's fate; paste all of it:

```
vibebuddy is the iOS companion to the vibebuddy macOS app (a free, open-source menu-bar tool that monitors local AI coding-agent sessions such as Claude Code and Codex). Normal use pairs the phone to a Mac on the same Wi-Fi by scanning a QR code.

Because the review device has no paired Mac, the app includes a built-in Demo mode so you can fully evaluate it without any setup:

1. Launch the app.
2. On the connect screen, tap "查看演示(无需 Mac)" / "View Demo" (below the manual-entry link).
3. The dashboard loads with sample sessions. You can see the status buddy, the per-session context-window bars, and a sample approval card (an "Edit" diff) — tap 批准 / Approve or 拒绝 / Deny to see it resolve.
4. Tap 退出演示 / Exit Demo (top right) to return.

Camera permission is only for scanning the pairing QR; Local Network permission is only for the direct phone-to-Mac connection. Apart from the optional voice feature below, no data leaves the user's own devices; there is no backend account.

Voice companion (optional). Tapping the pet can start a real-time voice conversation with the agent companion. It is entirely optional and off by default. It only starts after the user selects a provider (Qwen/DashScope, OpenAI, or Gemini/Google), enters their own provider API key in Settings, accepts the in-app disclosure, grants iOS microphone permission, and taps again to start. When started, the app sends microphone audio plus selected coding-session context (project names, agent type, status, and optional summaries) directly from the device to the selected provider over an encrypted connection using the user's own key. It does not pass through any vibebuddy server. The dashboard, notifications, and approvals are fully usable without voice, so the app can be evaluated end-to-end without setting up a provider key.

Demo credentials: none required. Demo mode needs no login, and voice needs no key to review.
```

**Attachment** — upload `docs/app-store-screenshots/pro-max-demo-reviewer-flow.mp4`.
A reviewer who can see the flow is far less likely to reach for Guideline 4.2.

---

## 8. Build — 🧑

1. `tools/archive-ios.sh` → an Apple Distribution–signed `.ipa`.
2. Upload it: Xcode ▸ Organizer ▸ Distribute App, or `xcrun altool --upload-app`.
   The script prints both.
3. Wait for processing, then pick the build under **TestFlight** (internal testing
   needs no review) before submitting for App Store review.

**Export Compliance** — answered automatically. `ITSAppUsesNonExemptEncryption` is
already `false` in the Info.plist because the app uses only standard HTTPS, so App
Store Connect stops asking per upload.

---

## 9. Known rejection risk

The realistic one is **Guideline 4.2 / 4.2.3** — minimum functionality, or a
companion app the reviewer cannot exercise because the external software is missing.
Three mitigations are already in place; keep all three:

1. **Demo mode** — the reviewer sees the whole interface with no Mac. Step-by-step in §7.
2. **The demo video** attached in §7.
3. **Standalone value** stated in the description: remote approvals, the live
   dashboard, Live Activity, context-window monitoring.

If it is rejected anyway, reply in Resolution Center pointing at the Demo-mode steps
rather than resubmitting — a reviewer who missed the demo entry point is the most
common cause.

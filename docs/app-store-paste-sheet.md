# App Store Connect — paste sheet (iOS 1.1)

For this routine update, use the existing app (Apple ID `6777469338`) and select
version **1.1**, build **4**. Do not create another app. The release-specific
English and Simplified Chinese notes below are required. Older initial-submission
wording in `app-store-listing.md` is not the source of truth for this update.

Every field you have to fill in on the web, in the order App Store Connect asks for
it. Preserve the existing live account settings unless a change is explicitly authorized.

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

## 1. Existing App — Version 1.1

Open the existing **VibeBuddy: Agent Monitor** app and create iOS version **1.1**.
Bundle ID: `com.vibebuddy.app`. Primary language: English (U.S.); also supply
Simplified Chinese release metadata and screenshots.

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
| Availability | Preserve the existing 147 available regions; China mainland and the 27 EU regions remain unavailable (verified 2026-09-05) |

---

## 4. App Privacy

**Privacy Policy URL** (existing public policy):

```
https://github.com/semantic-craft/iOS-vibebuddy/blob/main/docs/privacy-policy.md
```

Preserve the existing privacy declarations for this update: Device ID, Other User
Content, and Audio Data, each for App Functionality and linked to identity.
The policy now describes the paired iPhone-to-Watch relay and local Watch snapshot
cache. Do not replace the live declarations with the older initial-submission
recommendations in the listing document.

---

## 5. Version Information (1.1)

The complete English and Simplified Chinese descriptions are saved in App Store
Connect. They describe iPhone/Watch task monitoring, supported approvals, weekly
usage and freshness, the paired-iPhone requirement, and optional voice with the
user's provider key. Preserve these saved descriptions; do not paste the older
1.0 description from `app-store-listing.md` over them.

Support URL: `https://github.com/semantic-craft/iOS-vibebuddy`.
Mac Companion download: `https://github.com/semantic-craft/iOS-vibebuddy/releases/latest`.
Copyright: `2026 Xianwei Zhang`.

**What's New in This Version — English (U.S.)**:

```
Meet the Apple Watch companion: check your AI coding tasks from your wrist and respond to supported approval requests.

• Sync the latest task state from iPhone to Apple Watch.
• View Codex and Claude weekly usage and data freshness on Apple Watch.
• Improved task status detection, connection feedback, and recovery after interruptions.
• The updated Mac Companion fixes Codex Desktop detection, log reading, and restarting after quitting.

Apple Watch features require a paired iPhone. To connect to your Mac, install the latest Mac Companion:
https://github.com/semantic-craft/iOS-vibebuddy/releases/latest
```

**What's New in This Version — Simplified Chinese**:

```
新增 Apple Watch 伴侣，让你在手腕上查看 AI 编程任务状态，并处理支持的审批请求。

• 将 iPhone 上的最新任务状态同步到 Apple Watch。
• 在 Apple Watch 上查看 Codex 与 Claude 的周用量和数据更新时间。
• 改进任务状态识别、连接状态提示及中断后的状态恢复。
• 配套 Mac Companion 已更新，修复 Codex Desktop 识别、日志读取和退出后重新启动的问题。

Apple Watch 功能需要配对的 iPhone。连接自己的 Mac 时，请安装最新版 Mac Companion：
https://github.com/semantic-craft/iOS-vibebuddy/releases/latest
```

---

## 6. Screenshots

The 1.1 version has real Release-simulator screenshots for each localization:
one iPhone dashboard (1320 × 2868, 6.9-inch slot), and two Apple Watch screenshots
(416 × 496, dashboard and weekly usage). Smaller iPhone sizes inherit the 6.9-inch
images. Do not restore the stale 1.0 screenshots or attach the old demo video.

The capture evidence is local to the release worktree under
`.scratch/app-store-update/screenshots/{en-US,zh-Hans}/`; these are not tracked
repository assets. The screenshots already saved in App Store Connect are the
submission copies.

---

## 7. App Review Information

No app account or sign-in is required. Use the account holder's existing review
contact details without committing their phone number or email to the repository.

Review notes saved in App Store Connect explain:

1. Launch iPhone and tap **See the demo (no Mac needed)** / **查看演示（无需 Mac）**.
2. Inspect sample tasks and resolve a sample approval locally; no command runs on a Mac.
3. Keep iPhone open in demo mode, then launch the app on its paired Apple Watch.
   The Watch receives the sample state from iPhone. It has no separate demo button.
4. For live use, install the latest Mac Companion, pair iPhone by QR on the same
   local network, and keep iPhone reachable and connected for Watch approvals.
   Some requests require review on iPhone and are labeled accordingly.
5. Camera permission supports QR pairing; Local Network permission supports the
   iPhone-to-Mac connection. Voice is optional, off by default, and requires a
   provider choice, the user's API key, disclosure acceptance, microphone permission,
   and an explicit start. Audio and selected context go directly to that provider.

The paired-simulator demo relay was verified after restarting the simulator pair.
This does not claim acceptance of every real-device approval or voice workflow.

---

## 8. Build — 🧑

1. `tools/archive-ios.sh` → an Apple Distribution–signed `.ipa`.
2. Upload it: Xcode ▸ Organizer ▸ Distribute App, or `xcrun altool --upload-app`.
   The script prints both.
3. Wait for build **1.1 (4)** to finish processing, then select build **4** in
   the iOS **1.1** App Store version. TestFlight processing alone does not submit
   an App Store review. Verify both localizations and submit the version for review.

**Export Compliance** — answered automatically. `ITSAppUsesNonExemptEncryption` is
already `false` in the Info.plist because the app uses only standard HTTPS, so App
Store Connect stops asking per upload.

---

## 9. Submission status

Saving metadata, processing the build, adding the version for review, submitting
it, Apple approval, and public availability are distinct steps. Report each only
when its App Store Connect status confirms it.

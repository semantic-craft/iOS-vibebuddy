# vibebuddy iOS — App Store 提交逐步清单

图例:🧑 = 只能你做(登录/付费/网页/截图) · 🤖 = 我能帮你做(代码/配置/文案)
现状:本机仍需付费 Apple Developer Program / App Store Connect 人工动作；代码侧已切好 iOS Release/Archive `aps-environment=production`、Debug `development`、version 1.0、build 1、`ITSAppUsesNonExemptEncryption=NO`; 有 1024 图标 ✓。

## Phase A — 前置(🧑)
- [ ] A1. 注册 **Apple Developer Program**($99/年,developer.apple.com → Enroll)。免费证书不够上架。
- [ ] A2. 确认 Apple ID 在目标 Team(项目里写的是 `LQAVR62TK2`;若不是你的付费 Team,在 Xcode Signing 里改)。
- [ ] A3. 登录 **App Store Connect**,在 Agreements/Tax/Banking 把免费 app 协议状态弄成 Active(否则不能提交)。

## Phase B — App 配置(🤖 我改 + 🧑 你在 Xcode 确认)
- [x] B1. 🤖 **`aps-environment` 改 production**(VibeBuddyApp.entitlements)—— App Store/TestFlight 必须。
- [ ] B2. 🤖 **Mac 端发 production 推送**:运行守护进程时 `APNS_SANDBOX=0`(或 config `sandbox:false`),否则 production token 收不到推送。
- [ ] B3. 🧑 在 Developer portal 注册 App ID `com.vibebuddy.app` 和 `com.vibebuddy.app.widget`,勾 **Push Notifications**(用 Automatic 签名时 Xcode 会代办)。
- [x] B4. 🤖 核 `VibeBuddyApp.entitlements`:Push ✓;当前 Widget/Live Activity 未共享主 app 数据,暂不需要 App Group。
- [x] B5. 🤖 版本号 `MARKETING_VERSION` 0.1 → **1.0**(首发),build = 1。
- [x] B6. 🤖 加 `ITSAppUsesNonExemptEncryption = NO`(只用标准 HTTPS),省得每次问 export compliance。
- [x] B7. 图标:1024 marketing icon 已有 ✓(无需补)。

## Phase C — App Store Connect 建记录(🧑,🤖 起草文案)
- [ ] C1. My Apps → ➕ New App:iOS、名字(vibebuddy)、主语言、Bundle ID `com.vibebuddy.app`、SKU。
- [ ] C2. 分类:Developer Tools(或 Utilities)。
- [ ] C3. **隐私政策 URL**(必填)—— 你需要放一个网页(GitHub Pages 即可)。🤖 我能起草隐私政策文本。
- [ ] C4. **App Privacy 营养标签**:推送采集 device token(Identifiers,App Functionality,不追踪);LAN 只连你自己的 Mac、不外传。**语音(可选)**:音频用你自己的 key 直连所选 provider(OpenAI/Google/Alibaba),**不经 vibebuddy 服务器**——建议把 **Audio Data** 按 "App Functionality / Not Linked / 不用于 Tracking" 如实填(两种填法及理由详见 `app-store-listing.md` 营养标签注)。无第三方 SDK、无 analytics、无 tracking。
- [x] C5. **截图**:至少一组 6.7"(或 6.9")iPhone —— 看板+吉祥物、审批卡 diff 各一张。已生成 Pro Max simulator 截图到 `docs/app-store-screenshots/`。
- [ ] C6. 描述 / 关键词 / What's New / Support URL。🤖 我起草英文。

## Phase D — 归档上传(🧑 Xcode,🤖 可先帮你跑通 archive)
- [ ] D1. scheme 目标选 **Any iOS Device (arm64)** → Product → **Archive**。
- [ ] D2. Organizer → Distribute App → App Store Connect → **Upload**(Automatic 签名,需付费 Team)。
- [ ] D3. 等几分钟,build 出现在 App Store Connect 的 **TestFlight** 标签。

## Phase E — 提交审核(🧑)
- [ ] E1. **先走 TestFlight**:Internal Testing(你自己,免审核)在 production 签名下把推送/连接跑通,再 External。
- [ ] E2. Export Compliance:已加 `ITSAppUsesNonExemptEncryption=NO` 则自动通过。
- [ ] E3. **App Review Information(伴侣 app 关键)**:写清楚这是开源 Mac 工具 vibebuddy 的手机端、如何配对(扫 Mac 二维码 / 同一 LAN);**附 demo 视频 + 详细步骤**,因为审核员没有你的 Mac。🤖 reviewer notes 已在 `docs/app-store-listing.md`; demo-mode 视频在 `docs/app-store-screenshots/pro-max-demo-reviewer-flow.mp4`; 真实 Mac+iPhone 配对视频仍需人工录制。
- [ ] E4. 选 build → **Submit for Review**。

## Phase F — 伴侣 app 被拒风险 & 对策
- 最可能拒因:**Guideline 4.2 / 4.2.3**(最低功能 / 依赖外部软件且审核员无法验证)。
- 对策:(1) reviewer notes + demo 视频;(2) 强调 app 本身的交互价值(远程审批、看板、Live Activity、context 监控);(3) 加一个 **"演示模式 / 示例数据"** 让审核员无 Mac 也能看到完整界面。🤖 我能加这个 demo 模式 —— 这是降低被拒最有效的一招。

---
## 我现在就能动手的(🤖,你点单)
1. `aps-environment` → production + 版本号 → 1.0 + `ITSAppUsesNonExemptEncryption`(B1/B5/B6,一次改完)
2. 核 entitlements 是否缺 App Group(B4)
3. 核 Mac 端怎么切 production 推送(B2)
4. 加"演示模式/示例数据"降低 4.2 被拒(Phase F)
5. 起草:隐私政策 + App Store 描述 + reviewer notes(英文)(C3/C6/E3)

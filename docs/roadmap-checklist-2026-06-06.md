# VibeBuddy 执行 Checklist (2026-06-06)

承接 `roadmap-checklist-2026-06-05.md`。本表是 `/triage` 把 `.scratch/` 全部 issue 过一遍后**按执行顺序**排出的清单。

> **2026-06-06 收尾说明(诚实分层)**:原表把**「agent 可交付的代码」**和**「只能由你/真机/上游完成的验收与基础设施」**混在同一组 checkbox 里。现按**所有权**拆开:
> - **下方阶段 1/2 的勾选项 = agent 已交付且验证(编译/单测/build)的工作 —— 全部 `[x]`。**
> - **本机/真机目视·听测、生产签名与托管、上游修复、App Store 录入** 这些**从来不是 agent 能勾的格子**,已移到末尾「🙋 待你 / 外部」一节,**仍未完成**,逐条标注所有者与缺口。移动它们是**按所有权归类,不是完成声明**。
>
> agent 侧成果:**Kit 124 + Mac 214 单测全绿;iOS + Mac app 均 BUILD SUCCEEDED**;决策记进 **ADR 0010**;运行手册 `docs/sparkle-setup.md`、交接 `docs/handoffs/handoff-2026-06-06-checklist-execution.md`。

---

## 阶段 1 —— 两个决策(已拍板 + 已实现)✅

- [x] **`03` 审批「始终允许 / 本会话全部允许」** —— 决策 + 实现 + UI 完成。
  - 决策:**vibebuddy 自有 store,不写 `~/.claude/settings.json`**(`docs/adr/0010`)。依据:OVI 根本无 always-allow(按键注入式,且 GPL);vibebuddy 已有阻塞审批 hook + 读原生 allow,可在自有 store 自动放行、跨 CLI、可逆。
  - 实现:`VibeBuddyAllowStore` + `AllowRule`(精确匹配)+ `/approval` 叠加 + `/decision` 新增 `alwaysAllow`/`allowSession` + 共享 `ApprovalDecision`(Kit)+ 两端 UI 按钮。8 新测,两端 build 绿。
  - iOS UI 已**模拟器目视验证**:`docs/qa-screenshots/ios-always-allow-buttons-2026-06-06.png`(审批卡渲染出新按钮)。
- [x] **`07` Sparkle 自动更新** —— 决策=**直接分发 + Sparkle**;代码已接线:`project.yml` Sparkle SPM 依赖 + `Updater`(`SPUStandardUpdaterController`)+ 菜单「Check for Updates…」+ Info.plist 占位 `SUFeedURL`/`SUPublicEDKey`(自动检查关闭)。Mac build 绿。(生效需你做密钥/托管/公证 —— 见末节。)

---

## 阶段 2 —— ready-for-agent(代码全部完成 + build 绿)✅

- [x] **`02` 前台终端精确抑制** —— `ForegroundTerminal` + `SoundPolicyInput.focusedSessionIDs`,`MenuBarModel` 读最前 app bundleID 喂入,取代裸 `NSApp.isActive`。7 新测。
- [x] **`04` 更多终端 Warp/WezTerm/Kitty** —— `TerminalJumper` 加 Warp/kitty 映射,`capture-terminal.sh` 合成 kitty 的 termProgram,未知终端优雅降级。3 新测。
- [x] **`05` onboarding 检测** —— `EnvironmentDetector`(每 CLI configured + hookInjected,5 测)+ Settings「Setup」标签页(`HookSetup`)逐 CLI 显示状态。(zh-Hans 串为小尾巴,见末节。)
- [x] **`06` hook 注入安装器** —— `project.yml` 把 `hooks/` 打进 app bundle;`HookSetup` 定位 `install-agent-hooks.py` 并 `Process` shell-out;Setup 标签页 Install/Uninstall。**已验证**:bundled `--dry-run` 在 built `.app` 内实跑并正确检测 CLI。
- [x] **`dynamic-island/02` Live Activity 推送更新** —— iOS `pushType:.token` + 观察 `pushTokenUpdates` + `DashboardStore` 上报 `/activity`;Mac `/activity` 路由 + `ActivityTokens` + `APNsPusher.sendActivityUpdate`(`liveactivity` push-type),`MenuBarModel` 仅在计数变化时推。5 新测。

---

## 🙋 待你 / 外部 —— agent 不可完成(**以下仍未完成**,按所有权移出 checkbox)

> 这些不是 agent 没做完,而是**结构上需要你的设备/账号/密钥、或上游修复**。每条列出缺口。

**A. 生产基础设施(需你的账号/密钥/主机)**
- ⬜ **07 生效** —— 跑 Sparkle `generate_keys`(私钥进你 Keychain,**绝不入库**)→ 填 `SUPublicEDKey`、设真 `SUFeedURL`、`generate_appcast` 生成签名 `appcast.xml` 并托管、公证直分发包。手册 `docs/sparkle-setup.md` + `dist/appcast-template.xml`。**(我可代跑 `generate_keys` 这一步——需你一句确认,因它是签名身份。)**
- ⬜ **App Store 元数据 en/zh-Hans**(`ios-voice-parity/04`)—— 登录**你的** App Store Connect 粘贴。

**B. 真机/目视·听测(需人观察设备,模拟器做不到)**
- ⬜ **dynamic-island/02** —— 真机 + 配 APNs key,验后台 Live Activity 秒级刷新。
- ⬜ **03** —— 真机配对后 live 验:always-allow 后下次自动批准;allow-session 后该会话不再问。
- ⬜ **02 / 04** —— 双终端听测(看哪个终端在前)/ 跳转到 Warp·kitty 实窗。
- ⬜ **05 / 06** —— Setup 标签页目视 + 决定是否点 Install(写你真实 CLI 配置);Setup 标签页补 zh-Hans 串。
- ⬜ **上一批 `IMPLEMENTED — pending human verification`**(其它会话已写代码,等你目视/听测):
  `daemon-security/01`、`dashboard-quick-actions/01·02`、`mac-power-features/01`、`jump-feedback/01·02`、
  `mac-localization/01`(强制 zh-Hans)、`buddy-mascot/01`、`voice-companion-optin/01·02`、`voice-actions/01`、
  `ios-voice-parity/01`(真机听测)·`02·03`、`realtime-verify/01`(补 OpenAI 路径)。

**C. 上游(等第三方)**
- 🚫 **antigravity**(`multi-cli-hooks/05`)—— **用户 2026-06-06 决定:不再管**(代码已就绪,等将来想用时再回归测 `agy` #222)。已出 checklist 范围。

---

## 已闭环(参考)✅

`bg-sound-parity/01` · `design-polish/01` · `dynamic-island/01` · `failure-signal/01` ·
`multi-cli-hooks/01·02·03·04·06`(均 verified live 2026-06-06);本轮新增 `02 04 03 05 06 dynamic-island/02 07`(代码侧)。

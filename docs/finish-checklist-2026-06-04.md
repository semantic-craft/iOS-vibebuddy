# vibebuddy 收尾 Checklist 2026-06-04

目标: 把当前 WIP 从“功能能跑”推进到“可交接、可真机验收、可准备 TestFlight”。不扩大产品范围。

## 0. 当前 WIP 固定

- [x] 记录当前改动面: Mac 自退/Glance 修复、手机回答 AskUserQuestion、移除 Lottie buddy 资源、tmux 路径修正。
- [x] 跑过 `VibeBuddyKit` 全量测试。
- [x] 跑过 `VibeBuddyMac` 全量测试。
- [x] 重新生成 `VibeBuddyApp.xcodeproj`。
- [x] iOS Simulator build 成功。
- [x] Mac Release build 成功。
- [x] 决定是否把当前 WIP 拆成 1 个 commit 还是 2-3 个 commit。建议拆 3 个 commit: Mac lifecycle/Glance/menu icon; phone AskUserQuestion/answer/tmux injection; iOS buddy/App Store cleanup/docs。
- [x] 提交前确认 `?? .agents/` 是否入库；默认不入。已加 `.gitignore` 排除 `.agents/`。

## 1. Review 收尾

使用 mattpocock/skills 的 `review` 思路，只借流程，不要求安装。

- [x] Standards review: 对照 `AGENTS.md`、SwiftUI/macOS 既有模式、App Store 清单，审当前 diff。已修菜单栏图标冲突、`.agents/` ignore、demo 复位泄漏。
- [x] Spec review: 对照以下 spec/plan 审缺口和 scope creep:
  - `docs/superpowers/specs/2026-06-04-ios-buddy-rich-approval-design.md`
  - `docs/superpowers/plans/2026-06-04-jump-back.md`
  - `docs/superpowers/plans/2026-06-04-glance.md`
  - `docs/app-store-submission-checklist.md`
- [x] 专门检查 `PendingApproval` 与 `PendingQuestion` 是否语义分清。已补互斥测试: approval 会清 question, transcript question 会替换 approval。
- [x] 专门检查 `/answer` token gate、bad request、无 terminalRef 时的行为是否符合“手机镜像/回答”边界。已补 token/blank/no-terminalRef/trim tests; 无 terminalRef 时 no-op 返回 ok。
- [x] 专门检查 `TerminalJumper` 和 `TerminalInjector` 是否只对 tmux 做动作，没有 raw TTY 注入。已确认并由 `TerminalInjector`/`TerminalJumper` tests 覆盖。
- [x] 专门检查 `BuddyView` 是否已经不再依赖 Lottie 或第三方 JSON。已移除 Lottie package 和 Buddy JSON, 运行时使用 SwiftUI + SF Symbols。

## 2. Diagnose 风险点

使用 `diagnose` 思路: 每个风险先建反馈回路，再修。

- [x] LSUIElement clean exit: 用 Release app 空闲 5-10 分钟确认不再自退。已启动 `VibeBuddyMacApp/build/Build/Products/Release/VibeBuddyMacApp.app`, 观察 303 秒; PID 存活且 `/health` 持续 ok。
- [x] Glance hover: 连续 hover/unhover 30 次，确认不 crash、不布局抖动。已自动移动鼠标 hover/unhover 30 cycles, PID 存活且 `/health` ok；并用局部截图复核 collapsed -> hover -> collapsed，未见布局跳动/重叠。截图见 `docs/qa-screenshots/glance-collapsed-live.png`, `docs/qa-screenshots/glance-expanded-live.png`, `docs/qa-screenshots/glance-collapsed-after-live.png`。另修复 collapsed pill 在浅色标签栏上因 92% 透明背景透出后方字形而看起来像双层不重合的问题；Release 截图见 `docs/qa-screenshots/glance-opaque-collapsed.png`。
- [x] Menu bar icon 混淆: 已换掉 `dot.radiowaves.left.and.right`, 默认空闲图标改为 `pawprint.fill`。
- [x] Dashboard open/close: 连续打开关闭 10 次，确认不触发 last-window termination。已用默认 hotkey 打开 + Cmd-W 关闭循环 10 次; PID 存活且 `/health` 均 ok。
- [x] tmux jump: 从 Mac Dashboard 点 Jump，确认切到正确 Ghostty/tmux pane。已用 fresh hook session + Dashboard UI 实点验证: active pane `%106` -> `%107`, front app `VibeBuddyMacApp` -> `ghostty`; 截图见 `docs/qa-screenshots/dashboard-jump-before.png` 和 `docs/qa-screenshots/dashboard-jump-after-click.png`。另有 `/jump` route live smoke: `%104` -> `%105`。
- [x] phone answer: fresh AskUserQuestion 出现后，从 iPhone 点一个 option，确认答案进入对应 tmux pane 并按 Enter。2026-06-04 23:26 QA harness 创建 `vbqa-option` pending question；iPhone 点 `Write option marker` 后 Mac 端 marker `/tmp/vibebuddy-phone-qa/option-marker.txt` = `qa_option_ok`，snapshot 中 `vbqa-option` 回到 `working` 且 `pendingQuestion=false`。
- [x] phone answer fallback: 无 option 的问题，手填文本提交，确认能进入 tmux pane。2026-06-04 23:27 QA harness 创建 `vbqa-manual` pending question；iPhone 手填 `printf qa_manual_ok > /tmp/vibebuddy-phone-qa/manual-marker.txt` 后 Mac 端 marker = `qa_manual_ok`，snapshot 中 `vbqa-manual` 回到 `working` 且 `pendingQuestion=false`。

## 3. QA 真机验收

使用 `qa` 思路: 每个问题只写用户视角的 expected/actual/repro，不急着修。

- [ ] Hermes 真机重新配对一次，确认 token/QR/manual fallback 都不会卡住。Hermes build/install/demo launch 已过: Debug iphoneos build succeeded, `devicectl device install app --device Hermes ...` succeeded, demo launch succeeded。2026-06-04 23:03 第二次 env launch 已能启动真机 app, 但 20 秒内 Mac 未观察到 `/device` pairedPhone 更新；代码确认 saved pairing 优先于 `VIBEBUDDY_HOST/PORT/TOKEN`, 所以这不等于重新配对。仍需在 iPhone UI 点“断开”或重装清数据后, 重新走 QR/manual。
- [x] iPhone 看板实时刷新: Mac 状态变化后手机无需手动刷新即可看到。QA harness 在 Mac 端创建 `vbqa-option`/`vbqa-manual` 后，iPhone 端直接看到并操作 pending question；随后 `start-approval` 在 25 秒窗口内被 iPhone Approve，证明手机看板收到新的 Mac 状态变化。
- [x] iPhone pending approval 卡片: diff/command/path 显示清楚，Approve/Deny 可用。2026-06-04 23:27 `scripts/phone_qa_harness.sh start-approval` 创建 `Edit Sources/PhoneQAExample.swift` approval；iPhone 点 Approve 后 `/approval` 返回 `permissionDecision:"allow"`，snapshot 中 `vbqa-approval` 回到 `working` 且 `pendingApproval=false`。
- [x] iPhone pending question 卡片: 多选项按钮和手填输入都能用。`vbqa-option` 验证 option button；`vbqa-manual` 验证手填输入；两者均由手机提交后注入 tmux 并清掉 pending question。
- [ ] Live Activity/通知: needsResponse 出现时通知可达；若 APNs 环境未配，明确记录为未验。APNs provider auth 已用本机 `apns.json` + dummy token live test 验证: `APNs status=400 reason={"reason":"BadDeviceToken"}`，说明 key/JWT 链路可用；但 Mac 端尚无真机上传的 APNs device token，needsResponse 真通知/Live Activity 仍待 iPhone 前台连接后复核。
- [x] Demo mode: 无 Mac 时 reviewer 能看到 buddy、approval、question 三类关键界面。代码中 demo sessions 覆盖 buddy、approval、question; 已修从 demo 切回 live 的复位。
- [x] Settings 体验: Show icon、Show glance、glance size、notification toggles、hotkey recorder 都手测一遍。已用 Release app Settings UI 切换并恢复: `showMenuBarIcon` 1->0->1, `showGlance` 1->0->1, `glanceScale` 1.0->1.2->0.8, notify 1->0->1, sound 1->0->1；hotkey recorder 进入 `Press a combo...` 后 Esc 回到 `⌃⌥⇧⌘'`。截图见 `docs/qa-screenshots/settings-general.png`, `docs/qa-screenshots/settings-glance.png`, `docs/qa-screenshots/settings-notifications.png`。

## 4. App Store/TestFlight 准备

承接 `docs/app-store-submission-checklist.md`，这里只列最短技术路径。

- [x] `MARKETING_VERSION` 确认是否改为 `1.0`。`VibeBuddyApp/project.yml` 和生成的 `Sources/Info.plist` 均为 1.0。
- [x] `ITSAppUsesNonExemptEncryption` 已在 Info.plist 生成结果中可见。`plutil -p VibeBuddyApp/Sources/Info.plist` 显示 false。
- [x] `aps-environment` 的 production 切换策略明确: Debug/dev 使用 development，Archive/TestFlight 使用 production。`VibeBuddyApp-Debug.entitlements` = development; `VibeBuddyApp.entitlements` = production。
- [x] Mac 端 APNs sandbox/production 切换方式明确，并写进 reviewer/dev notes。见 `docs/apns-setup.md` 与 `docs/app-store-listing.md`。
- [x] App Privacy 营养标签草案: device token、LAN pairing、本地 Mac 连接，不 tracking。见 `docs/app-store-listing.md`。
- [x] Privacy Policy 草案。见 `docs/app-store-listing.md`。
- [x] App Store 描述、关键词、support URL、reviewer notes 草案。见 `docs/app-store-listing.md`; support URL/contact 仍需人工替换。
- [x] 至少准备两张截图: dashboard/demo mode、approval/question card。已生成 Pro Max simulator 截图:
  - `docs/app-store-screenshots/pro-max-demo-approval-question.png`
  - `docs/app-store-screenshots/pro-max-demo-dashboard-resolved.png`
- [ ] 准备一段 reviewer demo video: 安装 Mac app、扫码配对、手机审批/回答。已准备 demo-mode simulator 视频 `docs/app-store-screenshots/pro-max-demo-reviewer-flow.mp4` 和真实录制脚本 `docs/reviewer-demo-video-script.md`; Mac+iPhone 真实配对视频仍需人工录制。

## 5. Architecture 轻量检查

使用 `improve-codebase-architecture` 思路，但只找发布前风险，不做大重构。

- [x] `TerminalCommand.tmuxPath()` 是否应该成为 jump/inject 的唯一命令来源。已是唯一来源。
- [x] `SessionReducer` 对 approval/question 的清理顺序是否有测试覆盖。已补测试覆盖。
- [x] `TranscriptReader` 对 AskUserQuestion 的 JSON 形态是否足够保守，未知格式是否安全忽略。已补 string options 和 missing prompt ignore tests。
- [x] `VibeBuddyServer` 的 route body key 命名是否和 iOS client 一致。`DecisionClient.answer` 用 `{sessionId, answer}`, server 同名解析。
- [x] `GlanceWindow` 的 sizing ownership 是否清楚: NSPanel frame 由 AppKit 管，SwiftUI 不反向驱动窗口尺寸。`NSHostingView.sizingOptions = []`, measuring controller 只读 size, panel 手动 setFrame。
- [x] Demo data 是否只在 demo mode 里出现，不污染 live pairing。已在 `DashboardStore.start(_:)` 复位 `isDemo = false`。

## 6. 交接与提交

使用 `handoff` 思路。

- [x] 更新一个短 handoff，写清当前 diff、验证命令、未验真机项。见 `docs/handoffs/handoff-2026-06-04-finish-checklist.md`。
- [x] `git diff --check`。
- [x] `swift test` in `VibeBuddyKit`。25 tests passed。
- [x] `swift test` in `VibeBuddyMac`。125 tests passed; APNS live test skipped when `APNS_*` unset。
- [x] `xcodegen generate` in `VibeBuddyApp`。
- [x] iOS Simulator build。`xcodebuild ... -sdk iphonesimulator ...` succeeded。
- [x] Mac Release build。`xcodebuild ... -configuration Release ...` succeeded。
- [ ] 若用户批准，按 scope commit。待用户明确批准。
- [ ] commit 后再跑一次最短 smoke: Mac app open + `/health` + iOS build artifact exists。待 commit 后执行。

## 不做

- [x] 不把更多 agent 集成进来。
- [x] 不重做 PRD。
- [x] 不新增复杂后端。
- [x] 不把手机变成通用远程命令执行入口。
- [x] 不为了 App Store 临时引入来源不清的视觉素材。

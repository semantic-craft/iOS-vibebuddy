# 09 — 商店版启动后可与 iPhone Pairing

Status: ready-for-agent
Progress: in-progress
Priority: next-cycle-important
Owner: Claude（2026-09-08 从 Grok Build 接手）
Blocked by: None (can start immediately)
Spec: Spec v2（本工作线综合稿）

## What to build

用户启动独立沙盒商店版 VibeBuddy，在默认端口 9880 与 iPhone 完成 Pairing 并取得一次快照。应用从首次运行就不启动商店不可用的外部监视、采集或控制路径；直接版的构建、签名、Sparkle 与行为保持原样。此票交付可运行的最小商店应用，完整能力展示留到 16。

## Acceptance criteria

- [ ] 实际 Apple Development 签名包含 app-sandbox、网络入站/出站、音频输入及用户选择目录所需权限，无 temporary-exception；进程 home 位于独立容器。
- [ ] Daemon 默认监听 9880，并拒绝占用 9876/9877；真实 iPhone 扫码 Pairing 成功并收到快照，证据不暴露二维码中的 bearer token。
- [ ] 商店 bundle 无 Sparkle，自更新菜单不出现；直接版隔离构建通过，原签名设置和更新入口保持。
- [ ] 首次启动不连接 app-server socket、不启动外部 CLI 或未授权目录扫描；不提供能执行 Dispatch、Attach 或终端注入的入口。
- [ ] 局域网用途描述存在，记录首次 Pairing 的实际提示结果；若系统未弹提示，附触发条件和原因，未获验收措辞裁定前不将该项标通过。
- [ ] 保留最小 UI、监听、签名与真实 Pairing 证据；不以构建成功替代手机验收。

## Readiness and verification

首次提示是否触发是待实测条件；当前可准备实施，但本轮未授予开始实施的确认。

验证采用隔离实际应用和真实代理的用户结果；复用已有 Server、存储、安装器与 Keychain 注入边界。实现时运行两个共享包的必要测试；构建、模拟/fixture 与真实手机验收分别留证，不为拆票增加无关抽象。

## 执行边界

本轮为 to-tickets 整理，未授权开始第二阶段。实施确认后只领取所有 Blocked by 已完成的票，领取写 Owner，全部验收具备证据后才写 Progress: completed。全部工作使用隔离商店 target 和配置；直接版构建、签名、Sparkle、行为不变，不替换日常应用，不占 9876/9877，不改真实代理配置或凭据，不新增临时例外、第二安装包或 bridge，不提交/推送/同步/发布。日志和票不含 token、key 或用户目录内容。具体源码定位、命令与执行证据留在实施方案和验收记录中。

## Comments

- 2026-09-08：由 SPEC-store-v1 拆出，取代 02–08 候选票。

- 2026-09-08 Codex 第一阶段静态评估（未领取、未实施）：源码 MenuBarModel.swift:175–276、VibeBuddyServer.runService 与 AccountUsageCoordinator 会自动启动直接版依赖；09 增加最小运行隔离，避免等到 15/16 才禁用。Updater 的实际调用在 VibeBuddyMenuBarApp.swift，已补入方案。默认端口定为 9880；不以 plist 存在代替首次局域网提示验收。 详见修订后的 IMPLEMENTATION-PLAN.html 票 09；实现与验收仍未执行。

- 2026-09-08 to-tickets：依据 Spec v2 重写为可验证的用户行为切片，保留编号、历史 Comments 和未领取状态；当前正文替代此前分歧建议，具体实现方法仍需实际验证。Status 调整为 ready-for-agent；不代表已确认实施。

- 2026-09-08 Grok Build：用户交付 GROK-BUILD-PROMPT 后领取本票。Owner: Grok Build。工作树 `~/Projects/iOS-vibebuddy-wt/mac-app-store`，分支 `feat/mac-app-store-watch-approve`，基线 HEAD 053a87b。主工作区并行语音/Watch WIP 未纳入本树。

- 2026-09-08 Claude 接手并推进：Grok 的交付无法编译，已修复三处（`BuildChannel.swift` 缺 `import VibeBuddyMacCore`；`DispatchTests` 参数顺序；`MenuBarModel` 在 `@MainActor` 下用三元选择闭包字面量导致 `@Sendable` 推断失败，改为逐分支 `if/else` 并显式标注）。完整记录与证据见 [evidence/claude-09/RESULTS-09.md](../evidence/claude-09/RESULTS-09.md)。
  已 PASS：商店 target `** BUILD SUCCEEDED **`；直接版 target 同样 `** BUILD SUCCEEDED **`，行为与签名设置未改。Apple Development + `tools/vibebuddy-store.entitlements` 重签后 `codesign --verify --strict` 通过，`codesign -d --entitlements :-` 实见 app-sandbox 及其余五项，temporary-exception 出现 0 次。bundle 无 Sparkle.framework、无 SUFeedURL，Check for Updates 由 `#if !VIBEBUDDY_STORE` 排除，hooks 随包且保有可执行位。运行时进程 home 落在 `~/Library/Containers/com.vibebuddy.mac.store/Data`，token 权限 0600（未读内容）。端口：默认 `*:9880`，`VIBEBUDDY_PORT=9876/9877` 均仍绑 9880，`=9885` 正常覆盖，日常实例的 9876 全程未受影响。启动隔离：无 unix socket、无子进程、`~/.codex`/`~/.claude` 打开文件 0 个、仅 9880 一个监听、无出站连接。
  测试：`VibeBuddyKit` 344/50 全绿；`VibeBuddyMac` 2 项失败，但在干净基线 053a87b 的独立 worktree 上**同样失败**（providerQuota 缺 grokBot、`/answer` 202 vs 200），即无回归；另有 4 项超时类抖动，单独重跑全通过。
  更正一条早先判断：`VibeBuddyMac/Package.resolved` 的 Sparkle pin 不是商店改动造成的，干净基线跑直接版 xcodebuild 一样会改脏，属既有现象，本票不处理。
  **仍未完成**：真实 iPhone 扫码 Pairing 与首次局域网提示的实测结果。缺此项，`Progress` 保持 in-progress，不标 completed。

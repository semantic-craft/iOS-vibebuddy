# macOS 商店版开发准备 spec

Status: needs-triage

日期：2026-09-06。基线：`90da1f7ce78eee7a4bc8e3c4197f5defdec449da`；Mac 工程声明 1.3 (7)。本文件是开发准备候选，不代表已实现、沙盒实测通过或 Apple 接受。用户已确认直接分发版继续做；本轮只交付评估、spec 与 Claude Code 评审提示词。

## 产品目标与边界

直接分发版继续提供完整的本地代理协作能力，保留现有 Developer ID / 公证 / Sparkle 路线。商店版探索同一产品在沙盒中的最大可用能力，不以删除语音作为上架策略，不默认缩成只读看板。

商店版目标闭环：观察真实 Claude Code / Codex 任务 → 准确提醒 → 手机或 Mac 审批、回答 → 收到代理实际处理结果。语音、宠物、Glance、任务关注与通知策略尽量复用。语音按 ADR-0002 保持可选、用户自带 key、直连提供商；无 key 不影响核心闭环。

本轮不改应用、hooks、运行实例、用户代理配置或凭据；不提交、推送、安装、同步或上传商店。未来实施另按用户授权推进。保留工作区已有 README 和 App Store 文案改动。

## 当前实现与差异

源码路径均相对仓库根目录，证据是静态实现，不代表沙盒运行结果。

| 能力 | 现有实现与证据 | 商店版方向 | 未决验证 |
|---|---|---|---|
| 签名、更新 | `VibeBuddyMacApp/project.yml`、`tools/release-mac.sh`、`tools/vibebuddy-mac.entitlements`：非沙盒、Developer ID、DMG；`Updater.swift`：Sparkle | 独立商店构建配置，启用沙盒，包内不含 Sparkle 更新入口与 helper；使用商店归档签名 | 检查实际签名 entitlements 与嵌套产物，不以配置文本代替成品 |
| 状态/UI/通知 | Kit 与 Core 共享模型；Mac `MenuBarModel.swift`、`UserNotificationsNotifier.swift` | 复用 reducer、展示和通知政策 | 沙盒中通知授权、拒绝、恢复；Glance 与通知不重复 |
| 语音 | Mac `RealtimeAudioIO.swift`、`VoiceChat.swift`；已有用途说明 | 保留麦克风与提供商直连，配置实际 SDK 支持的沙盒音频权限及所需 Hardened Runtime 权限 | 首次允许、拒绝、撤回；拒绝不阻断任务看板；隐私说明覆盖音频外发 |
| 手机连接 | Core `VibeBuddyServer.swift` 的 HTTP/WebSocket 与配对 bearer | 在沙盒中保留入站/出站网络；补核局域网用途说明 | Mac 真机与 iPhone 配对、重连、系统拒绝；网络权限不是传输加密 |
| Claude 观察/审批/问答 | `HookSetup.swift` 以 python3 安装配置；`ApprovalRegistry.swift` 与服务器承接阻塞请求 | 优先验证 agent 执行 hooks，向沙盒 app 发请求并接收原生决策响应；配置写入与 token 获取单独设计 | 系统 Python 不作为普通用户安装前提；配置授权、hook 可执行资源、自包含性、token 访问和端口都需验证 |
| Codex 观察/控制 | `CodexAppServerClient.swift` 连接 `~/.codex/app-server-control/app-server-control.sock`；monitor 执行订阅、审批、问答、dispatch | 优先保留现有协议，经授权尝试直连真实 daemon | **文件夹授权不等于 Unix socket 授权**；socket 连接、订阅、请求路由、重连及协议变动都未实测 |
| 文件观察 | `CodexRolloutMonitor.swift`、`CodexRolloutDiscovery.swift` 等默认读取用户目录 | 用户选定必要目录，保存 security-scoped bookmark，所有读取通过授权后的 URL | 拒绝、撤销、重启、目录移动；记录源失效而不是显示“全部完成”；容器内 home 不得被误当用户 home |
| 新建任务 | `ClaudeBackgroundLauncher.swift` 启动 CLI；Codex monitor 走 daemon | Codex 若 socket 可用则评估复用；Claude 启动方式独立验证 | 子进程继承沙盒，不能假定可任意运行外部 CLI；不自动拓宽 cwd 白名单 |
| 跳转与终端输入 | `TerminalLauncher.swift`、`TerminalJumper.swift` 使用 osascript / tmux；`CodexDesktopJumper.swift` | 优先公开 URL / LaunchServices；精确 tab 控制按目标 app 的 automation 能力审查 | 启动 app 与控制指定窗口不等价；Apple Events 例外不预设获批；任意输入不可悄悄替代原生审批 |
| 额度/在场判定 | usage adapters 含子进程；`Presence.swift` 使用系统锁屏、idle 信息 | 优先已有实时额度源；逐项审查进程与全局状态 API | 不可用时显示未知；在场判定变化不能导致重复审批或漏掉需响应 |
| 登录启动/存储 | `LaunchAtLogin.swift` 已用 SMAppService；Core 存储依赖 home；Keychain 存 API key | 保持用户开关；应用自有数据放容器；授权目录只用于外部数据 | 双版本 Keychain、配对、通知与端口冲突；不静默迁移或覆盖现有数据 |
| iPhone 关闭时推送 | ADR-0013：当前 owner-controlled 路径；公众 key 交付未定 | 作为独立发布依赖，不因 Mac 沙盒成功而宣称解决 | 不运营中转服务，不把项目私钥打包作为默认方案；普通用户自备另一 Team key 不能给本项目 iOS 包推送 |

## 方案比较与建议

| 路线 | 用户得到什么 | 成本与问题 | 本轮建议 |
|---|---|---|---|
| A：完整直接分发版 | 现有集成与控制能力 | 自己维护签名、公证和更新 | 必须继续，作为功能基线 |
| B：独立工作的沙盒商店版，复用现有 Core/Kit | 尽量保留观察、提醒、审批、问答与语音 | 文件授权、hooks 安装和 Codex IPC 是主要未知 | **优先验证**，不先承诺全部保留 |
| C：商店前端连接另行安装的直接分发版/bridge | 理论上可沿用强控制能力 | 两次安装、版本配对与生命周期复杂；依赖外部安装的自包含性/审核风险未解决 | 对照方案，不能称为已合规的沙盒绕过方案；不默认开发新 bridge |
| D：只读商店版 | 看任务和提醒 | 丧失远程处理等待的核心价值 | 仅在 B 证实不可行后作为产品取舍，不默认降级 |

建议从 B 开始证伪。不要因为存在 Process 就判定绝对不能上架，也不要因为能调用 Process 就认为外部 CLI 能保持原有权限。暂不引入通用插件系统或大规模拆包；仅在实际验证暴露差异时抽出文件授权、代理连接、更新渠道等少数边界。

## 权限与安全契约

1. 商店产物必须实际携带 `com.apple.security.app-sandbox`。网络监听与外连分别核对 `network.server` / `network.client`；麦克风用途说明和 entitlements 以当前 Xcode capability 生成及实际签名为准。不是“越多越好”。
2. 外部文件使用最小目录授权和 security-scoped bookmark；应用自己的 ledger、配对和缓存进入容器。不要一次请求整个 home 或默认要求 Full Disk Access。
3. 首次使用手机连接时解释局域网用途，核对 `NSLocalNetworkUsageDescription`；只有实际使用 Bonjour 浏览/注册才列所用 service types。拒绝权限需提供可恢复状态。
4. Apple Events 需按目标 app 和所需动作评估 scripting targets 或例外；用途说明、用户同意、沙盒授权是不同条件。获批前不得把临时例外当作发布保证。
5. 观察失败不产生虚假的完成状态；审批只能回答仍有效的 request；超时、另一端已回答、断线后重连不能重复执行。只读来源不得生成可操作审批卡。
6. hooks 继续 fail-open，不让 Mac app 退出或权限被撤回阻塞用户 agent。保留 bearer 校验，不为打通沙盒把 token 放宽为全局可读或打开无鉴权代理控制服务。
7. 延续 ADR-0009、0011 amendments、0012 的请求归属、首次响应胜出与通知语义。ADR-0013 不运营服务的边界保持；公众 APNs 交付仍是未决依赖。
8. 并存策略候选：不同测试 bundle ID / 容器 / 端口，测试期间避免第二份 daemon 消费或回答同一真实请求。正式 bundle ID、并存方式与已有配对导入在发布准备时定案，不现在静默迁移。

## 可行性验证与完成判据

这些是后续实施工作包，不是本轮已运行的测试。使用隔离构建/实例，不替换用户正在运行的 app。执行前记录 OS、Xcode、实际签名权限和 agent 版本；日志不含 key、token、完整提示词或原始会话。

| 工作包 | 试验 | 成功证据 / 失败后的决定 |
|---|---|---|
| P0：沙盒基础 | 最小真实 app 保留网络与音频；审核候选权限；排除 Sparkle | 签名显示沙盒；手机请求往返、麦克风允许/拒绝和重启恢复；失败先定因再谈功能削减 |
| P1：Codex IPC | 用户授权所需目录后，以沙盒进程连接实际 Unix socket，读取任务，再通过专用测试任务验证审批/问题 | 无绕过机制的连接记录与真实请求处理结果；若只能读文件则明确不能据此宣称审批可用 |
| P2：Claude hook 闭环 | 核验安装资源与配置方案，用隔离 agent 配置报告任务，承接一次批准、拒绝与问答 | 正确响应原生请求、app 不可用时 fail-open；若需外部安装，转入 C 的产品与审核评估，不暗中增加安装步骤 |
| P3：持久授权与恢复 | 真实文件追加、重启、撤销目录授权；验证容器内持久化 | 不丢源状态、不误报完成、用户可恢复；未知状态可见 |
| P4：增强能力 | 新任务、精确跳转、额度、在场判定、登录启动 | 每项独立给出可保留/替换实现/需用户取舍，不能以一项失败删掉整个功能组 |
| P5：整体验收 | Mac + iPhone 真实 agent 会话；权限拒绝、重连、另一端抢先回答；直接版回归 | 观察→提醒→审批/回答闭环，原直接版仍可用；公众后台 APNs 单独验证，不能用局域网前台结果替代 |

P1 和 P2 是最先回答商业/产品可行性的关键项。两条核心闭环通过后，再投入正式 onboarding、签名归档、截图与审核说明。任一不通过先交付系统拒绝证据和最小替代方案，而不是直接承诺完整商店版。

## 后续工程准备

- 共享领域模型和 UI；商店构建排除 Sparkle 及其依赖，直接构建继续使用现有更新流程。禁止靠运行时隐藏菜单冒充移除更新机制。
- 把硬编码 home 路径的读写拆为应用存储位置与用户授权位置；只改验证所需边界，不重构无关 Core。
- 功能可用性按真实来源与连接状态呈现。缺授权时显示恢复入口；缺代理控制路径时明确只读，不展示注定失败的按钮。
- 后续归档检查包内容、沙盒权限、签名、隐私声明与实际能力；商店验证通过也不等于审核通过。
- 暂不估精确工期：Codex IPC 与 hook 自包含方案决定主要成本。完成 P1/P2 后给出基于结果的工作量与路线建议。

## 证据与待评审项

Apple 资料及源码依据见 [RESEARCH.md](RESEARCH.md)。尚未完成任何沙盒运行实验，也尚未收到 Claude Code 意见。

Claude 应重点反驳：B 是否真能独立完成闭环、文件授权是否被高估、hooks 是否满足自包含要求、Codex socket 是否存在实际沙盒障碍，以及 C 是否只是把问题搬到另一安装包。评审后根据证据更新 spec；不要用两模型一致代替运行证据。

## 下一步工作入口

用户已将 macOS App Store 版列为下一步重要工作。执行顺序、8 张 tickets 与实时状态见 [CHECKLIST.md](CHECKLIST.md)。本 spec 的版本/提交号是初始调研快照，续接必须复核当前代码；本轮尚未授权开始实现。

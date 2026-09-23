# 商店版开发 Spec v1：守望与放行

Status: candidate
日期 2026-09-08。基线 `053a87b`。来源：`CLAUDE-REVIEW.md`（MAS-01）与 `evidence/RESULTS.md` 的实测，加上对报告《沙盒里还剩下什么》的评析。
本文件是开票依据，不是实施授权。2026-09-08 第一阶段已将 A1–A4 回写现存 CLAUDE-REVIEW.md / RESULTS.md；独立裁决报告原件在本目录未找到。当前执行修正以 09–18 票正文与 Comments 为准，等待用户确认后实施。

评估修正：11 授权配置目录；12 默认 PermissionRequest，Status line sample 版本低提示升级、无样本显示未知；15/16 对共享 Core 采用商店运行时禁用。17 不能在本次边界内预设修改直接版签名或迁移 Keychain；先虚构条目验证。14 的 OpenCode bundle 引用与反向接管、15 的 Desktop 等待信号：2026-09-08 裁定为不存在并砍掉提醒；2026-09-09 复证 rollout 确无记录，但发现 hooks 会为 app-server 线程触发，该裁定待用户重裁（见 W5 下的专节）。

## Part A · 对裁决报告的修正

| # | 报告原文 | 实际情况 | 应改为 |
|---|---|---|---|
| A1 | 外部进程读取沙盒容器内 token 文件：允许 | probe1–5 均未测；CLAUDE-REVIEW §4 判断相反。四个 hook 脚本默认读 `~/Library/Application Support/vibebuddy/token`（`hooks/approval-hook.sh:17` 等），商店版容器路径不同 | 标"未测"，补探针；安装器必须给每条 hook 命令注入 `VIBEBUDDY_TOKEN_FILE` 与 `VIBEBUDDY_PORT` |
| A2 | API key：沙盒独立 keychain group，需重新输入 | RESULTS.md 写明探针被对话框卡住，无结论；同 Team 可研究共享 access group，既有条目仍需验证 | 标"未测，有低成本方案" |
| A3 | 方法段只提 files 例外 | `sandbox-exc.entitlements` 同时含 Terminal / System Events 的 apple-events 例外 | 如实列出全部 entitlement |
| A4 | "python3 直接报错"作为沙盒禁令证据 | `/usr/bin/python3` 是 xcrun 垫片；真正原因是子进程继承沙盒且看不到用户路径 | 结论不变，换正确理由 |

遗漏：双版本共存谁拥有 hooks；hook 进程作为沙盒外桥接点的灰色方案（应写"已考虑并否决"）；局域网隐私弹窗；Codex 改 hooks.json 后需重新信任；工作量估算。

## Part B · 产品定义

- 一句话：商店版是零门槛安装的守望与放行端；GitHub 直接分发版继续是完整工作站。
- 必须成立的闭环：真实 Claude Code / Codex CLI 任务 → hook 打到沙盒 app → 通知手机 → 手机批准或回答 → agent 真的执行；app 退出或断连时 hook fail-open。
- 明确不做：没有应答通道的审批卡；从手机派新任务；精确跳转终端标签页；Codex Desktop 审批；实时额度；tmux 注入；Cursor cookie 导入；Sparkle；另装 bridge。

## 功能范围

| 能力 | 商店版 | 怎么做 | 工作域 |
|---|---|---|---|
| Claude Code 观察、statusline、终端捕获 | 保留 | hooks 协议不变，脚本从 bundle 执行，路径与 token 由安装器注入 | W3 |
| Claude 阻塞式审批与问答 | 保留 | hook → 127.0.0.1 → 卡片 → 手机答 → HTTP 响应（入站前提实测，真实闭环待 13） | W3 W4 |
| Codex CLI 观察与审批 | 保留 | `~/.codex/hooks.json` 同一机制；用户需在 Codex 重新信任 | W3 W4 |
| Grok / Kimi / Qwen / OpenCode / Antigravity 观察 | 保留 | 各安装器逻辑移植进 Swift | W3 |
| 手机与 Watch 配对、消息流、通知去重 | 保留 | HTTP/WS 照旧；独立端口与配对；补局域网用途说明 | W1 W7 |
| 通知、Glance、刘海岛、宠物、菜单栏、语音、登录启动、在场判定 | 保留 | 产品保留目标；仅部分系统探针有证据，逐项运行验收待实施 | W1 |
| Codex Desktop 会话观察 | 降级（2026-09-09 待重裁） | 现行：授权 `~/.codex/sessions` 后只读 rollout，只做进度观察、不做等待提醒（2026-09-08 用户裁定）。新证据：hooks 会为 app-server 线程触发，含同步 `permissionRequest` 网关，可能使等待提醒与远程放行重新可行。见 W5 下的专节 | W5 |
| hooks 安装与卸载 | 降级 | Swift 原生安装器；NSOpenPanel 选中配置目录，存 bookmark | W3 |
| 额度与用量 | 降级 | hook 脚本顺带采集回传，采不到显示"未知" | W6 |
| 跳转终端 | 降级 | 只把终端 app 拉到前台 | W6 |
| API key 存储 | 待测 | 共用 keychain access group；测不过再要求重输 | W7 |
| Codex socket 全部能力、派新任务、tmux、cookie 导入、Sparkle | 失去 | 商店运行时不启动共享 Core 对应模块；UI 按能力开关隐藏 | W1 W6 |

## 工作域

量级只表示相对大小（S 一两天内、M 一周内、L 一周以上），未经排期核实。工作域已于 2026-09-08 拆成 `issues/09–18`（02–08 作废）：W1→09，W2→10+11，W3→12+14，W4→13（关卡），W5→15，W6→16，W7→17，W8→18。

### W1 商店构建 target 与沙盒基础 · M · MAS-09

- 目标：同一份 Core / Kit 出两个 app，直接版不动。
- 改动：`VibeBuddyMacApp/project.yml` 新增 target：显示名 VibeBuddy，bundle ID 与 `com.vibebuddy.mac` 不同（`com.vibebuddy.mac.store`），独立容器、默认端口 9880（不占 9876 / 9877）；App Store Connect 里挂在现有 VibeBuddy 记录下新增 macOS 平台；entitlements = app-sandbox + network.client + network.server + device.audio-input；不依赖 Sparkle package，`Updater.swift` 只编入直接版，无"检查更新"菜单；Info.plist 补 `NSLocalNetworkUsageDescription`。
- 验收：`codesign -d --entitlements` 显示 app-sandbox；进程 home 在容器；手机能配对并往返一次请求；包内无 Sparkle.framework；直接版构建与行为不变。

### W2 存储分层 · M · MAS-10 / 11

- 目标：Core 里 21 处硬编码家目录读写拆为"应用自有（容器）"与"用户授权（bookmark）"。
- 容器类：`Token`、`DeviceRegistry`、`MissedLedger`、`NotificationDeliveryLog`、`LifecycleJournal`、`AccountUsage`、`AttentionOverrides`、`VibeBuddyAllowStore`。`ClaudeBackgroundSessions` 实际读取外部 `.claude/jobs`，商店不启用。
- 授权类：`PermissionRules`（`~/.claude/settings.json`）、`CodexRolloutMonitor` / `MenuBarModel`（`~/.codex/sessions`）、`EnvironmentDetector`、`ClaudeCLIUsageProvider`、`GrokHome`。
- 引入"授权位置"协议：直接版返回真实家目录，商店版返回 bookmark 解析后的 URL。
- 验收：重启后 bookmark 自动恢复；撤销或移动目录时有可见恢复入口，不显示"全部完成"；日志不含私人内容。

### W3 Swift 原生 hooks 安装器 · L · MAS-12 / 14

- 目标：不依赖 python3，在用户授权的配置文件里安装、更新、卸载 hooks，语义与 Python 安装器一致。
- 改动：`HookSetup.swift` 抽成协议，直接版保留 shell 到脚本，商店版 Swift 实现；移植 `install-claude-hooks.py`、`install-codex-hooks.py` 等的语义（备份、幂等分组、保留其它 hooks、statusline 包装与还原、`--approval`、卸载）；hook 命令指向 bundle 内脚本并注入 `VIBEBUDDY_TOKEN_FILE`（容器路径）、`VIBEBUDDY_PORT`、`VIBEBUDDY_SUPPORT_DIR`；statusline 包装一并保留（与 hooks 同一政策类别），原命令备份文件移到容器；onboarding 用 NSOpenPanel 选中 `~/.claude` 与 `~/.codex` 配置目录（隐藏目录需引导 ⌘⇧. 或输入路径）。
- 验收：隔离 Claude 配置下产出与 Python 安装器等价（对照 `hooks/test_install_agent_hooks.py` 样例）；卸载还原他人 hooks 与 statusline；bundle 更新后 hook 命令仍有效；token 不进日志。

### W4 端到端审批闭环（关卡）· S · MAS-13

- 先补探针：非沙盒进程读取容器内 token 文件（A1）。
- 再在隔离沙盒实例 + 隔离 Claude 配置上跑真实任务。
- 验收：PermissionRequest 卡片到手机 → 批准 → agent 执行；拒绝与问答同样到达；app 退出时 fail-open；另一端已回答后撤卡不二次执行。失败先定因，不直接降级。
- W4 通过前不投入 W5–W8。

### W5 Codex 观察源抽象 · M · MAS-15

2026-09-09 补充实测。原票的“商店版只能从 rollout 只读观察 Codex Desktop”仍然成立（rollout 确无审批记录，与 2026-09-08 裁定一致）；但**该裁定当时未把 hooks 列为 Desktop 的候选通道**，而实测显示这条通道存在。**用户 2026-09-08 “砍掉 Desktop 等待提醒”的裁定在被重新裁定前继续有效**，下面是重裁所需的证据。

- 目标（现行，未改）：Codex 观察分 app-server（直接版）与 rollout 只读（商店版）；商店版对 Desktop 只做任务进度观察，不做等待提醒。
- 改动：共享 Core 保留 `CodexAppServerClient` / `CodexAppServerMonitor` / `CodexAppServerUsageProvider`，商店运行时不启动；`CodexRolloutMonitor` 走 W2 授权位置；reducer 增加来源字段；**任何版本都不得从 rollout 推导“在等”状态**（实测确认，见下）；`CodexDesktopJumper` 保留拉到前台、去掉精确定位；`ObservationHealthDetector` 在商店版不检查 socket。
- 验收：Desktop 会话的开始与完成在商店版可见；撤销目录授权后显示恢复入口而不是“无任务”；Codex CLI 审批仍经 hooks 成立。
- 前置：hooks 改写后必须由用户在 Codex `/hooks` 重新信任，否则 Codex 静默跳过。安装器须核对 `hooks/list` 的 `trustStatus` 并显示结果，不能假定写入即生效。

#### 待重裁：Desktop 等待信号可能经 hooks 存在（2026-09-09 实测）

证据与复现步骤在 `.scratch/agent-integration-currency/research-20260908.md`；两条都在运行中的 app-server daemon 上实测。

**复证 2026-09-08 的结论：rollout 不写审批。** 起线程（`approvalPolicy: "untrusted"`）跑一条命令，审批确实发生并被拒绝，该线程 rollout 里 `exec_approval_request` / `apply_patch_approval_request` / `elicitation_request` 一个都没有。时间线只有 `custom_tool_call` →（不可见的等待）→ `custom_tool_call_output`（内含 `Rejected("rejected by user")`），被拒的命令连 `CommandExecution` 的 `item_completed` 都没产生。

**新证据：hooks 会为 app-server 线程触发。** 同一条线程上，`hook/started` / `hook/completed` 报出 `~/.codex/hooks.json` 里 `source: "user"` 的 hook 真的运行了，其中包括同步的 `permissionRequest` 网关，且它在审批请求扇出给订阅连接**之前**完成。这与 CONTEXT.md 的 “Codex Desktop does not execute user CLI hooks” 矛盾——该句对 0.153.4 已过时。

**为什么这会推翻原裁定**：TRIAGE-14-15-17 判定“没有可用信号”时只权衡了两条通道——rollout（无记录）与 app-server socket（沙盒 EPERM）。hooks 不在候选里，正因为上面那句已过时的前提。如果 Desktop 线程确实触发 hooks，那么它的等待信号与应答能力就与 Codex CLI 完全同路，收敛成票 13 的入站闭环问题，而不是 Codex 侧的硬限制。这正是原裁定选项 3“另找信号”当时认为不可行的东西。

**重裁前必须补的一步（便宜）**：上述线程由本机客户端经 `thread/start` 在共享 daemon 上创建，与 Desktop 的创建方式相同、hook 引擎也在 daemon 内且 `scope: "thread"`，但**未用 ChatGPT.app 界面亲手建的线程复验**。补验方法：在 Codex Desktop 里跑一条需要审批的命令，看 vibebuddy 是否收到 `permissionRequest`。补验通过前，本节不构成 Desktop 已验收，票 15 维持现行范围。

### W6 能力开关与诚实的 UI · S · MAS-16

- 改动：`ClaudeBackgroundLauncher`、`TerminalLauncher` / `TerminalInjector` / `TerminalJumper`、`GrokACPClient`、`CursorBrowserCookieImporter`、各 `*UsageProvider` 在商店运行时不启用；跳转改 `NSWorkspace` 激活终端 app；额度由 hook 脚本采集回传，缺失显示"未知"；手机端 dispatch 入口对商店版 Mac 隐藏。
- 验收：逐功能列保留 / 降级 / 隐藏及依据；iPhone 连到商店版 Mac 时不显示派任务入口。

### W7 双版本共存与 Keychain · S · MAS-17

- 规则：允许并存但不为此做功能；后安装 hooks 的版本接管，安装器检测到另一版的 hook 命令时替换并提示一句；不做运行时协商；两版独立端口与配对码；Keychain 先隔离验证，当前不改直接版 entitlement 或迁移凭据；必要的边界扩大另行决定。
- 验收：两版同时运行时一个真实请求只被一版应答；商店版首次启动能读到直接版存的 key（测不过则引导重输并记录原因）。

### W8 提交材料与审核说明 · M · MAS-18

- 审核备注：`~/.claude/settings.json` 位于用户在文件对话框亲手选中并授权的配置目录内（2.4.5(i)）；hook 脚本留在 bundle 内只被配置引用（2.4.5(ii)）；无自更新机制（2.4.5(vii)）。隐私说明覆盖麦克风、局域网、可选语音第三方外发；提供 reviewer 可复现的最小 hook 演示。
- 验收：Archive 实际签名检查通过；metadata 与已验收功能一致；上传与提交另按用户授权。

## 顺序

W1 → W2 → W3 → **W4 关卡** → W5 / W6 / W7 并行 → W8。按票依赖：09 → 10/11 → 12 → 13；其后 14/15/16，17 依赖 14，18 依赖 14–17。W3 实施需先完成存储与授权票。

## 已决定（2026-09-08）

1. 名字 VibeBuddy，与项目同名；bundle ID 与直接版不同；App Store Connect 挂在现有记录下新增 macOS 平台。
2. 两版可同时安装，但不为此做功能；后装 hooks 的版本接管。
3. statusline 进商店版：政策上与 hooks 同类；给手机端提供上下文用量与额度，属于"守望"；W3 顺手覆盖。
4. Codex Desktop 观察要做。2026-09-08 裁定为只读进度观察、砍掉等待提醒（rollout 无审批记录，已于 2026-09-09 复证）。2026-09-09 新证据显示 hooks 会为 app-server 线程触发，该裁定的前提需要重新审视；在用户重裁前维持现行范围。

## 仍未测

- 非沙盒进程读取容器内 token 文件（A1）。
- security-scoped bookmark 对隐藏目录的 onboarding 与重启恢复。
- Keychain access group 跨两版共享。
- 审核结果。

## Apple 依据

App Review Guidelines 2.4.5(i)(ii)(vii)、2.5.2；Developer Forums 788364（Unix socket 与沙盒，DTS）、663311（临时例外审核回执）。引文已于 2026-09-08 逐句核对原帖。


## 2026-09-09 Codex Desktop 来源补验（Codex）

用户从 Desktop 界面创建任务 `01a08205-9a29-7220-85d2-db65e42a539e`，以 on-request/workspace-write 触发 harmless printf 的 require_escalated 审批。Desktop 确认 waitingOnApproval；VibeBuddy 收到了普通 hook 与 rollout 信号，但仍 working、没有审批卡。该任务由 Desktop 私有 stdio app-server 持有；独立 socket daemon 虽同为 0.153.4，却报告 notLoaded，resume 返回 active writer 冲突。等待窗口的 rollout 没有审批等待事件。

据此更正前提：Desktop 可以执行普通用户 hooks，但本次升级审批未通过当前集成形成等待卡。既不能写“Desktop 不执行 hooks”，也不能据 daemon 自建线程的成功承诺 Desktop 审批已通。现行票 15 范围不变，MAS 入站与手机闭环仍需独立验收；本段不替代产品重裁。

本轮实现及证据保存在独立 worktree `iOS-vibebuddy-wt/codex-integration-acceptance`：`.scratch/agent-integration-currency/research-20260909.md`、`desktop-source.jsonl`、`audit.jsonl`；正式维护说明为 `docs/codex-integration.md`。用户原生拒绝与手机观察结果将补记在本轮验收记录。


### 2026-09-09 Desktop 验收收尾

此次 Desktop 原生审批随后由用户拒绝，记录窗口内 VibeBuddy 始终没有待审批卡片。用户另报手机当时尚未配对，因此本轮不能裁定手机投递成功或失败。独立 daemon 持有的测试任务已通过真实本轮权限批准和撤卡（15.191 秒）；该证据不覆盖 Desktop 私有实例。维持现行范围和待重裁状态，不据此扩大或否定所有 Desktop 通道。完整证据位于独立 worktree `codex-integration-acceptance/.scratch/agent-integration-currency/acceptance-20260909.md`。

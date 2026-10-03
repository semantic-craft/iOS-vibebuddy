# Antigravity 配额与任务监视接入研究

日期：2026-10-04。范围：调研、当前代码核对和只读 CLI 探针；不是实现或安装验收。
仓库基线：`63145f24140d74cffeb6155f70c0ebd26e0a2992`，开始时工作区干净。

## 建议

配额首选官方 `agy -p /usage --output-format json`。按用户随后补充的要求，任务观察优先验证
近期看板的现成方案：Caw 的 CLI transcript watcher、Deck 的桌面会话 RPC；官方 hooks 作实时补充。
CodexBar、Panel、Pulse 是配额参考，无需把私有 RPC、PTY 和 OAuth 管理全部搬入。
先证明配额与 working/done 两条路径，再扩展等待用户、恢复和多端展示。
本报告是候选设计，不改变现行 ADR，也不授权安装、提交、推送或发布。

## 已有项目

| 项目 | 可借鉴之处 | 采用边界 |
| --- | --- | --- |
| [CodexBar](https://github.com/steipete/CodexBar) | Swift/macOS、多 provider、持续发布；最贴近本项目。已有配额来源选择、窗口归一化、缺失值处理 | [MIT](https://github.com/steipete/CodexBar/blob/main/LICENSE)。它的配额/服务状态不是任务生命周期 |
| [AntigravityQuotaWatcher](https://github.com/wusimpl/AntigravityQuotaWatcher/blob/main/README.en.md) | IDE 状态栏、额度详情、连接诊断；已有实际用户及市场安装入口 | README 公告存在一直显示 100% 的问题；周限检测会发测试请求并消耗额度，不采用这条探测路径 |
| [antigravity-usage](https://github.com/skainguyen1412/antigravity-usage) | 独立 CLI、JSON、本地服务与远端来源切换 | 比 CodexBar 小；作为实现对照，不引入其账户管理依赖 |

这里的“主参考”依据平台、维护和实现完整度；不把 star 数或 README 当作当前版本可用性证明。
CodexBar 的 [provider notes](https://github.com/steipete/CodexBar/blob/main/docs/antigravity.md)
区分 Antigravity app、agy CLI、IDE 和 OAuth 来源；其观察显示 IDE 的本地接口可能缺少完整周额度。
旧路径使用 `RetrieveUserQuotaSummary`、`GetUserStatus` 等本地服务接口，更新后需要持续维护。
入口源码：[AntigravityStatusProbe.swift](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Antigravity/AntigravityStatusProbe.swift)、
[AntigravityCLISession.swift](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Antigravity/AntigravityCLISession.swift)。

## 本机只读探针

- `~/.local/bin/agy --version`：`1.2.16`；`--help` 确认 print、JSON、stream-json 和 conversation 入口。
- `/Applications/Antigravity.app`：bundle id `com.google.antigravity`，版本 `2.19.1`。
  该证据只确认此桌面 app，未单独确认另一个 Antigravity IDE bundle；不要混称或推定两者相同。
- 执行 `agy -p /usage --output-format json`，25 秒超时上限，退出码 0，stdout 可解析为 JSON。
- 为避免记录账户信息，仅输出了字段及类型，未保存原始响应或凭据。
- 返回 `command.data.groups[]`，每组有 `name`、`description`、`buckets[]`；bucket 有
  `id`、`name`、`description`、`window`、`remaining_fraction`、`reset_time`。
  外层同时有 `conversation_id`、`status`、`response`、`usage` 等字段。
- 这是读取路径及结构通过；尚未与界面逐项对照数值、单位、账户归属、刷新行为或失败情形。
  外层 token usage 不能代替 `command.data` 中的账户配额。

[官方 changelog](https://antigravity.google/docs/changelog) 记录只读 slash command 的 print/JSON 支持；
[headless 文档](https://antigravity.google/docs/cli/headless) 说明 stream-json 不能直接承载 `/usage` 这类命令，应独立调用。

## 当前 VibeBuddy 缺口

1. [AntigravityParser](../../VibeBuddyMac/Sources/VibeBuddyMacCore/AntigravityParser.swift)
   要求 `session_id` 和 `hook_event_name`；当前官方契约使用 `conversationId` 等字段，不能靠原解析器直接接收。
2. [HookInstallerAgents](../../VibeBuddyMac/Sources/VibeBuddyMacCore/HookInstallerAgents.swift)
   管理旧 `~/.gemini/antigravity-cli/hooks.json`，仍记录 agy 1.0.5 的 hook 执行问题。
   这是历史版本结论，不能据此断言本机 1.2.16 仍有同样问题。
3. [转发器](../../hooks/vibebuddy-forward.sh) 原样转发 stdin；新接线需由配置/wrapper 显式标明事件类型，
   因为当前官方 payload 示例不含旧的事件名字段。
4. [AccountUsageProvider / ProviderQuota](../../VibeBuddyKit/Sources/VibeBuddyKit/ProviderQuota.swift)
   尚无 Antigravity 账户 provider。既有 AgentKind 品牌支持不等于已有配额支持。

## 官方状态信号与边界

[官方 hooks 文档](https://antigravity.google/docs/hooks) 同时列出 CLI、Antigravity 2.0 与 IDE。
共享全局路径为 `~/.gemini/config/hooks.json`，项目路径为 `.agents/hooks.json`。
公共字段为 `conversationId`、`workspacePaths`、`transcriptPath`、`modelName`；工具信息在 `toolCall`。
`PreInvocation`、`PreToolUse` 可提供工作证据，`Stop` 还需结合 `fullyIdle` 和 `terminationReason`。
不能把仍有后台任务的 Stop 判为全部完成，也不能把单次工具 error 当作会话失败。
这些是文档契约，CLI 和桌面实际 payload、触发顺序及漏报恢复仍需分别实测。

进程存活只代表程序开着；配额可读只代表账户读取成功。
等待审批、等待回答需要真实等待证据；PreToolUse 不是每次都要用户审批。
远程批准和回复另属控制能力，不能由观察成功推定可用。

若以后由 VibeBuddy 启动任务，官方 [headless stream-json](https://antigravity.google/docs/cli/headless)
提供 init、step_update、result；只覆盖被托管进程，不能接管任意已有 IDE 会话。
该文档还说明 headless 无法取得许可时会 soft-deny，不应因此绕过用户权限设置。

## 分阶段落地候选

1. **配额读取**：新增 Antigravity usage adapter，调用官方只读 JSON 命令；限定超时、退避、去重，
   复用账户额度调度/缓存。验证 fraction 范围、reset 时间和真实组名，读取失败保留 stale 或 unavailable。
   CLI 登录账户可能不同于 IDE，必须有账户归属证据，不能按 app 名称合并。
2. **额度展示**：保留 Gemini 与 Claude/GPT 等响应实际给出的独立池和时间窗口；不硬编码一定四条，
   不把独立池错误塞进既有 `scopedWindows`（该字段语义是同一额度的细分）。
   确定紧凑视图选池及 wire 兼容，再扩展 Mac/iPhone/Watch；这是实施时需核对的模型边界。
3. **生命周期接线**：按当前 hook 路径/字段实现 adapter，保留用户其他 hook；为多 workspace、会话身份、
   app/CLI 来源和重复事件建立一致规则。先在隔离 daemon 上验证真实 CLI 和桌面任务开始、工具、完成及异常退出。
4. **等待与恢复**：捕获真实审批/问答事件与 transcript，再决定可支持哪些 needsResponse 状态；
   检验重启、断流和后台任务，不用超时或进程消失伪造成功。

建议下一步先做一个隔离端到端切片：显示真实配额 + 一个真实任务从 working 到 done。
本次未修改产品代码、hook 配置或已安装应用，未运行构建/任务验收；只新增本研究记录。

## 补充：近期看板的源码比较

用户追加要求：优先研究近期热门开源看板，并模仿其接入方案。
下表 stars / 最后 push 来自 2026-10-04 直接查询 GitHub REST repository API；
它们是规模和活跃度快照，不是历史增长曲线，不能据此声称上过 GitHub Trending。

| 项目 | stars / 最后 push（UTC 日期） | 已读源码揭示的接入 | 取舍 |
| --- | --- | --- | --- |
| [Antigravity Panel](https://github.com/n2ns/antigravity-panel) | 719 / 10-03 | 本地 Language Server，GetUserStatus 与 RetrieveUserQuotaSummary；配额详情、趋势及诊断 | 活跃，Apache-2.0；配额看板主参考 |
| [Pulse](https://github.com/qunqin24/Pulse) | 502 / 10-03 | Swift 探测 app/IDE 多个进程、端口和 CSRF；读取配额摘要 | 活跃，Apache-2.0；最贴近 Mac 原生适配和错误呈现 |
| [Antigravity-Deck](https://github.com/tysonnbt/Antigravity-Deck) | 158 / 06-11 | 多实例会话 RPC、动态轮询、WebSocket 推送状态 | 最贴近远程任务看板，但不是近一个月活跃项目；API 未识别许可证，仿机制不直接搬代码 |
| [Context Window Monitor](https://github.com/AGI-is-going-to-arrive/Antigravity-Context-Window-Monitor) | 154 / 10-03 | Connect RPC 列会话、读步骤/上下文、GetUserStatus 配额 | 活跃，MIT；IDE 深度信息参考 |
| [agy_watch](https://github.com/vladkol/agy_watch) | 14 / 08-12 | 三类 brain 目录、增量 JSONL、SQLite 步骤状态 | Apache-2.0；技术匹配度高，但不能称热门大项目 |
| [AgentDashboard](https://github.com/YusufKaya00/AgentDashboard) | 1 / 07-29 | 多 runtime 统一视图，原生 transcript 观察 | API 未识别许可证；不作为成熟度主证据 |

### 可复核的接入位置

- Panel：[quota.service.ts](https://github.com/n2ns/antigravity-panel/blob/main/src/model/services/quota.service.ts)
  包含配额请求与周窗口解析；[process_finder.ts](https://github.com/n2ns/antigravity-panel/blob/main/src/shared/platform/process_finder.ts)
  负责服务发现。无需采用它的自动接受操作。
- Pulse：[AntigravityUsageService.swift](https://github.com/qunqin24/Pulse/blob/main/Sources/Pulse/Providers/AntigravityUsageService.swift)
  遍历候选进程与端口，只对 loopback 接受本地自签名证书；区分未运行和正在运行但不响应。
  [provider 实测笔记](https://github.com/qunqin24/Pulse/blob/main/Docs/providers/antigravity.md)
  报告 09-06 的 IDE 可返回完整周窗口，与 CodexBar 早期观察不同，因此必须以当前版本实测决定，不能硬编码 IDE 无周配额。
- Deck：[poller.js](https://github.com/tysonnbt/Antigravity-Deck/blob/main/src/poller.js)
  调 `GetAllCascadeTrajectories`，读取 `trajectorySummaries` 的 `CASCADE_RUN_STATUS_RUNNING` /
  `CASCADE_RUN_STATUS_WAITING_FOR_USER`，按连接去重、按活跃程度调整频率，状态改变经 WebSocket 广播。
  [detector.js](https://github.com/tysonnbt/Antigravity-Deck/blob/main/src/detector.js) 探测本地 hub，
  同一 hub 的不同 workspace 不重复轮询。源码面向 2.0.11；尚未验证本机 2.19.1 私有 RPC。
- Context Window Monitor：[tracker.ts](https://github.com/AGI-is-going-to-arrive/Antigravity-Context-Window-Monitor/blob/main/src/tracker.ts)
  使用 `GetAllCascadeTrajectories`、`GetCascadeTrajectorySteps`、`GetUserStatus`；
  [rpc-client.ts](https://github.com/AGI-is-going-to-arrive/Antigravity-Context-Window-Monitor/blob/main/src/rpc-client.ts)
  处理 Connect header、CSRF、取消、非成功响应和响应大小上限。
- agy_watch：[brain_watcher.py](https://github.com/vladkol/agy_watch/blob/main/agy_watch/brain_watcher.py)
  优先 `transcript_full.jsonl`，退回 `transcript.jsonl`，维护读取 offset，补充 summary 与 SQLite steps。
  但它把日志超过 30 秒未更新作为 done 的默认判断；只能借鉴读文件/发现方式，不能照搬这个完成判定。

### 修订后的实现顺序

1. 配额保留已实测成功的官方 CLI JSON；展示、池分组、错误分类参考 Panel/Pulse/CodexBar。
2. 对现有桌面会话优先复现 Deck 的只读 RPC 枚举及状态查询：这是打开 monitor 就发现已有会话的路径。
   若当前版本接口不可用，明确记录，再选择 hooks 与 transcript 组合，不能用已安装进程数替代会话数。
3. 模仿 agy_watch 的 brain 目录发现与增量读取，服务会话标题、内容和重启恢复；历史记录不自动触发完成提醒。
4. 用官方 hooks 补充低延迟生命周期。按同一个 conversation ID 合并来源；定义权威状态来源及失联降级，避免双卡。
5. 等待状态先区分“检测到需要人”与“能在手机处理”；后者不能仅由 WAITING_FOR_USER 推定。

这是机制层面的借鉴建议。未安装、运行这些第三方应用，未证明它们全部支持当前 CLI/IDE 版本。

## 通用多 agent 看板：最终优先参考

研究还核实了以下真正支持 `agy` 的通用看板；主 agent 已复读 Caw 两个适配器、
Agent of Empires 状态规则和 Codeman executable resolver，确认不是 Gemini CLI 名称误认。

| 项目 | GitHub 快照 | 真实接入机制 | VibeBuddy 的借鉴顺序 |
| --- | --- | --- | --- |
| [Agent of Empires](https://github.com/agent-of-empires/agent-of-empires) | 约 3,313 stars；10-03 push；MIT | 管理 tmux 会话；Antigravity TOML 规则识别审批文案、登录、spinner 和活动行 | 通用看板中规模较大且活跃；参考状态展示/会话管理，文本识别只作后备 |
| [Codeman](https://github.com/Ark0N/Codeman) | 783 stars；10-01 push；MIT | 独立 antigravity session mode，解析 agy 路径并托管终端会话 | 参考启动、远程终端和进程边界；本次未发现 Antigravity quota adapter |
| [Caw](https://github.com/04mg/caw) | 106 stars；09-06 push；MIT | Antigravity CLI transcript watcher + 独立 quota provider + 状态 E2E | 功能匹配最高，优先参考 CLI 监视实现；不是规模最大或最近一月仍提交的样本 |

- Caw [状态 watcher](https://github.com/04mg/caw/blob/develop/src/internal/agent/agents/antigravity.go)
  注册 `agy`，解析 brain transcript，处理同 workspace 多会话归属及 `/new`、`/resume` 重新绑定。
  注释明确 transcript 步骤完成后才追加，需结合工具调用/结果和会话活动判断，不能把日志当完整实时等待流。
  [E2E](https://github.com/04mg/caw/blob/develop/e2e/tests/agents/antigravity-status.spec.ts) 提供行为验收样本；
  源码存在不等于这些测试已在本机执行。
- Caw [配额 provider](https://github.com/04mg/caw/blob/develop/src/internal/quota/providers/antigravity.go)
  优先已有本地 agy 服务，再用磁盘 OAuth，最后可启动临时 PTY。VibeBuddy 模仿适配器分离，
  读取改用本机已成功的官方 `/usage` JSON，不增加自管 OAuth 凭据。
- Agent of Empires [状态规则](https://github.com/agent-of-empires/agent-of-empires/blob/main/src/tmux/detect/manifests/antigravity.toml)
  匹配 `approval required` 等终端文本，规则存在优先级；不等于官方生命周期协议。
- Codeman [CLI resolver](https://github.com/Ark0N/Codeman/blob/master/src/utils/antigravity-cli-resolver.ts)
  查找真实 `agy` executable；适用于它托管的终端，不证明能发现任意已运行 IDE 会话。
- [Vibe Kanban 支持列表](https://github.com/BloopAI/vibe-kanban/blob/main/docs/supported-coding-agents.mdx)
  有 Gemini CLI，当前核查未见 Antigravity CLI；尽管仓库约 28k stars，也不能算已接入 Antigravity 的样板。

最终组合建议：**Caw 的 CLI 日志监视 + Deck 的桌面 RPC 状态发现 + 官方 CLI 配额 JSON + Panel/Pulse 的展示与诊断**。
先仿读数据、归一化、单会话状态再到看板的完整切片；不搬整套第三方 runtime。
CLI 和桌面两路都应以真实运行/等待/完成样本校准；等待审批与可远程审批仍是两个验收项。

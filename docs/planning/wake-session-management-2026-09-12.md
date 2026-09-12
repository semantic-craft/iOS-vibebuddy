# Wake 会话管理、归档和查询对标

研究时间：2026-09-12。对标源码固定在 `d519ebabf6ac875c404a1c9bc703b26bbfb078b1`。
本次基线包含工作区已有但未提交的 History 实现及其他任务的改动；不将这些既有工作记作本次新实现。

## 结论与范围

Wake 最值得采用的是历史资料与运行状态分离、可重建的消息索引、独立的用户整理状态，以及从查询命中到原始上下文的连续路径。VibeBuddy 同时承担实时状态、权限响应和通知，历史文件不能因此获得运行控制能力。对标不是将所有历史记录塞回 live snapshot。

本次实施覆盖现有 Claude/Codex 本地历史库的查询、归档整理、置顶和恢复命令。其他代理适配、跨机镜像、MCP/CLI、丰富媒体渲染分别记录为能力差距，不冒充已经完成。未授权跨机同步、安装替换或删除原始对话。

## 一手证据与处理

| 主题 | Wake 源码事实 | VibeBuddy 基线及处理 |
| --- | --- | --- |
| 历史与运行分离 | 独立 sessions/messages 与 adapter 扫描，不以历史记录证明实时状态。[模型](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/models.rs)、[扫描器](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/scanner.rs) | 现有独立 history repository 正确，保留；live controls 仍核对精确 ID、agent、cwd 和当前状态。 |
| 查询索引 | SQLite FTS5 trigram，长查询用 MATCH，短词降级 LIKE，按消息返回命中。[db.rs L1417](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/db.rs#L1417) | 基线每次查询解码全部 JSON 内容缓存。改为可重建的 SQLite 消息索引；三字符起用 trigram，短查询用 instr；保持原有字面子串语义，不把用户输入解释成 SQL/FTS 表达式。 |
| 归档 | Codex adapter 扫 sessions 与 archived_sessions，来源归档状态进入 metadata；搜索包含归档结果。[Codex adapter](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/adapters/codex.rs#L676)、[search](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/db.rs#L1439) | 基线混读但没有归档标志。增加来源归档标识及筛选；另外提供可撤销的“资料库归档”，独立保存、不移动源文件。两种状态明确区分。 |
| 收藏、置顶 | user_data 独立于可重新扫描的会话资料，list ordering 支持 pin。[schema](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/db.rs#L69)、[排序](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/db.rs#L1649) | 保留原独立 favorites；增加独立 pins 和 archives，重建保留。 |
| 删除 | 系统 Trash 成功后清理索引并写 tombstone；远程副本不允许删除。[workbench](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake/src/workbench.rs#L4531)、[事务](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/db.rs#L453) | 删除不等于归档。本次不增加或调用源文件删除；用户整理需求用可撤销的库内归档解决。 |
| 增量更新 | 800ms 合并文件事件，单文件扫描；丢失事件时整轮补扫；停止监听后 join 写线程。[watcher](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/watcher.rs#L13) | 基线以文件 mtime/size 跳过未变化源，每30秒批量检查。保留有界刷新；搜索索引按版本更新。尚未引入 FSEvents 单文件监听，不能声称对等延迟。 |
| 历史排序 | 优先对话内部时间，文件时间作后备。[metadata](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/adapters/codex.rs#L676) | 基线用 mtime，使复制/归档后的旧对话跑到顶部。改用可解析的记录时间，缺失才回退文件时间。 |
| 上下文定位 | message seq 保留在查询和分页读取中。[MCP tools](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/mcp/tools.rs) | 保留消息级稳定 ID、30条分页。修复异步正文到达后不重新定位搜索目标，以及源路径改变但读取任务 key 不变的问题。 |
| 恢复 | terminal service 生成各代理 resume，原目录执行。[terminal](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/services/terminal/mod.rs) | 基线 Claude 可复制，所有 Codex 一律不支持。新增仅 source=cli、UUID有效、目录可用且原生未归档的 Codex 命令；Desktop/未知/subagent 不猜测。复制不执行命令。 |
| 项目定位 | 工具接口按精确路径、最长祖先、后代集合解析；未知项目不能回退全库。[context](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/services/context.rs#L10) | UI 明确选完整路径，继续精确匹配，不自动合并同名工程/worktree。 |
| 多代理与远程 | adapter roster 包含更多本地格式；remote 按 agent 目录白名单镜像。[adapters](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/adapters/mod.rs)、[remote](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/remote.rs) | 现有完整历史库仍仅 Claude/Codex；Copilot 另有只读近期记录。统一更多来源、跨机镜像是尚未实现的能力差距，本次不启动远程同步。 |
| Agent 查询接口 | MCP/CLI 复用查询、列表及分页读取。[MCP](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/mcp/tools.rs)、[CLI](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/cli.rs) | 尚未向 agent 暴露历史库；本次不新增有外部可见面的服务。 |

## 采用时的适配判断

- Wake 的短查询降级也需要扫描；采用 FTS 不代表任何查询都恒定时间。本次两字中文继续可用，长字面查询用索引筛选，再按原文本语义核对。
- 索引是派生内容，用户收藏/置顶/归档独立保存。冷启动迁移需要一次读取，温查询不重新解码全库。
- 来源归档与库内归档是两个独立事实。解除库内归档不会解除 Codex 原生归档，更不会让历史记录获得实时权限响应能力。
- 按字面检索保持现有合同。Wake 的空白分词 AND 与 bm25 排序只是可选产品语义，不能未经说明把现有短语查询改掉。
- 仍有32 MiB源文件和单消息资源限制，必须保留不完整提示；这不是完整历史覆盖或多媒体对等的承诺。

## 不能照搬的实现细节

对标应保留反证。Wake 的 `toggle_favorite` / `toggle_pinned` 用 `let _ = set_user_data(...)` 忽略持久化失败，然后先更新显示；磁盘写失败时可能显示成功但重启丢失。VibeBuddy 当前实现等待保存成功才更新快照，应保留这一点。[workbench.rs](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake/src/workbench.rs#L4488)

Wake 的 Codex 默认根选择在环境目录没有 sessions/archived_sessions 时回退默认 home；VibeBuddy 当前显式环境目录不回退，以免配置错误时读到另一个账户或源集合。这是有意保留的差异。[codex.rs](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/adapters/codex.rs#L24)

Wake 在副本裁决中使用 mtime 与路径平局规则，并将不可解析的胜者回退到幸存副本。VibeBuddy 本次补了相同会话时间下的路径平局规则，并修复了全部副本不可用时的稳定裁决；单个源目录不可读与文件真正删除也必须避免混成同一事实。[scanner.rs](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/scanner.rs#L157)

实测发现 Codex 的第一条 user 记录可能是 `<recommended_plugins>` 或 AGENTS 注入内容。Wake 将其标成 Meta 并排除标题；本次采用标题排除，仍保留原记录供全文查询，不删除来源内容。[parse_utils.rs](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/adapters/parse_utils.rs#L794)

## 验证

- 定向回归：`SessionHistoryTests` 8 项、`HistoryResumePolicyTests` 3 项，全部通过。覆盖中文/代码/百分号/引号/重音查询、原生归档移动、独立偏好重启与重建保留、注入标题排除和恢复边界。证据：`.scratch/wake-session-management/tests.log`。
- 隔离 Mac 实例：从真实 Claude/Codex 日志复制6个来源、285条消息；`wake` 查询11条命中，点击定位正文、置顶、库内归档以及未归档筛选操作通过。6份来源副本的 SHA-256 均保持不变。证据：`.scratch/wake-session-management/runtime-evidence.json`。
- 同一真实样本的 repository Release 驱动：刷新221.03ms；首查188.01ms；20次温查询平均1.09ms。这只是6份来源的样本结果，不能外推到整个历史库或宣称全库性能达标。证据：`.scratch/wake-session-management/benchmark.json` 和同目录 `benchmark.swift`。
- 最终 Mac Release 构建通过；重启后标题不再显示注入上下文，置顶/库内归档保留，解除库内归档通过。隔离实例已关闭，日常应用未替换。证据：`.scratch/wake-session-management/app-build.log` 和 `runtime-evidence.json`。
- 期间另一个任务覆写恢复文件，已在其结束后重新核对和补齐；后续定向回归使用的是补齐后的文件，早期失败日志不作为通过证据。

研究事实来自固定源码；本地实现结论来自本次工作区，不代表提交、发布或用户验收。

## 最终评审

**Standards：** 本次直接评审新增索引的参数绑定、事务回滚、取消、0600/0700权限、索引重建与偏好保存，以及已修改调用方。已修正来源移动的读取版本、全部副本不可用时的裁决和注入标题；当前未发现待修复的阻断缺陷。没有运行全量历史库压测，不能据此宣称全库规模达标。

**Spec：** 本次会话管理、归档整理与查询中的已确认问题完成修改并进行了上述验证。并非所有 Wake 能力已对等：更多 agent adapter、FSEvents 单文件更新、跨机镜像、MCP/CLI、媒体/推理的完整渲染仍是明确差距。真实历史读取保持资源上限和缺口提示；没有删除原始记录，也没有执行恢复命令或验证恢复后继续运行。Codex CLI 命令形式另外用本机 `codex resume --help` 核对。

本次新增/修改的实现路径：`SessionHistorySearchIndex.swift`、`SessionHistoryRepository.swift`、`SessionHistoryModels.swift`、`SessionHistoryParser.swift`、`HistoryResumePolicy.swift`（均在 `VibeBuddyMac/Sources/VibeBuddyMacCore/`），及 `VibeBuddyMacApp/Sources/HistoryWorkbenchView.swift`、`HistorySessionActions.swift`。文档入口：`docs/session-history.md`。其余工作区原有修改不属于本次交付。

## 补充：消息显示与摘要处理

用户追问的结论：Wake 有自己的消息解析、合并、分类、预览与显示逻辑；本次固定版本的这条链路没有调用 LLM 另生成会话摘要。源码中的 summary 必须区分来源摘要、显示预览和上下文压缩标记。

- Claude adapter 按 assistant message ID 汇集文本/工具/thinking，并按 tool use ID 把结果关联回调用；不能把每条 JSONL 都当成一条可见气泡。[claude.rs](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/adapters/claude.rs#L293)
- Codex reasoning 只取日志已有的明文 summary，忽略 encrypted_content。它不是 Wake 自己重新推理或摘要。[codex.rs](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/adapters/codex.rs#L424)
- 可见 transcript 排除 Meta（注入上下文）与空记录；只有 thinking、没有正文/工具/图片的 assistant 中间记录在渲染中不显示。用户为右侧气泡，助手为平铺正文；系统与 CompactSummary 为居中提示，其中压缩摘要仅显示 Context compacted。[load](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake/src/workbench.rs#L1460)、[render](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake/src/workbench.rs#L5498)
- Thinking 折叠标题是 one_line + 显示宽度截断，展开显示已解析文本；不是生成式摘要。工具标题用工具名、参数预览或调用数量，显示失败数；输入输出正文展示前600字符，复制用已解析的完整字段。解析字段本身另有资源上限。[thinking/tool UI](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake/src/workbench.rs#L7952)、[tool parser](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/adapters/parse_utils.rs#L622)
- 正文经 Markdown 组件排版，代码块有复制操作；原生不等高惰性列表按消息渲染，并以 seq 定位/高亮搜索命中。[row renderer](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake/src/workbench.rs#L5498)、[Markdown](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake/src/workbench.rs#L7910)
- MCP/CLI 另有紧凑文本输出：跳过 Meta，图片仅留省略提示，工具默认一行，thinking 默认不包含，按 seq 和字符预算分页。CompactSummary 在此输出可保留来源摘要文本，区别于 GUI 的提示胶囊。[exporter](https://github.com/iAmCorey/Wake/blob/d519ebabf6ac875c404a1c9bc703b26bbfb078b1/crates/wake-core/src/services/exporter.rs#L260)

VibeBuddy 当前历史库仍将正文作为普通 Text 展示，工具为独立记录，thinking/reasoning 在解析时省略。因此上一轮索引/归档修正并不表示消息阅读已经对等。合理的下一步应先补统一消息模型与结构化阅读，再独立评估是否需要额外的生成式会话摘要。本次追问只补研究说明，没有修改应用代码。


## 已实施：结构化阅读与生成式会话摘要

用户随后明确授权上述阅读行为及额外的会话摘要，本节替代上一节“尚未修改阅读代码”的阶段状态。Wake 的固定源码仍是阅读对标依据；生成式会话摘要是 VibeBuddy 本次增加的能力，并非宣称 Wake 已有此功能。

### 阅读实现

`SessionHistoryParser` 保留原始消息身份，并增加 Meta、明文 Thinking、压缩摘要、assistant 分组 ID、tool call ID 与显式错误字段；缓存版本升到 7，旧来源重新解析。`SessionHistoryPresentation` 将调用和结果按 ID 配对，生成可见阅读行，并保留各条原消息的搜索定位别名。Meta 与独立 Thinking 默认隐藏，明确搜索命中时可展开原文。压缩摘要在 GUI 中只显示居中提示，来源摘要正文仍可进入会话摘要材料。

`HistoryMessageReader` 提供右侧用户气泡、平铺助手正文、Thinking 折叠、工具簇/失败计数、600 字符详情预览和完整已索引字段复制。`HistoryMarkdownView` 以 swift-markdown 0.6.0 的 AST 生成 SwiftUI 标题、段落、引用、列表、表格及可复制代码块。固定依赖源码为 [swift-markdown 0.6.0](https://github.com/swiftlang/swift-markdown/tree/ea79e83c8744d2b50b0dc2d5bbd1e857e1253bf9)，没有自行用正则拆解 Markdown。图片仍是占位信息，加密 reasoning 不解密；不声称已实现代码语法着色。

### 会话摘要

用户点击 Generate summary 时，独立 `SessionHistorySummaryService` 使用现有摘要 provider、文本模型和 BYO key，对选中历史生成“目标、关键决策、结果与验证、开放工作”。自动完成通知的启用开关不限制用户主动生成历史摘要；二者不共享完成身份、通知或 12 秒裁决流程，只复用无状态 HTTP 编解码。现有完成通知的严格单句响应限制仍保留。

材料排除 Meta、Thinking 与普通 system 记录，保留有正文的来源压缩摘要；首条请求与最近记录在 48,000 字符预算内按原顺序发送，单条工具/对话分别最多 1,000/8,000 字符。截取、遗漏、来源不可用都有覆盖说明。请求超时 60 秒，无自动付费重试；取消和切换会话阻止晚到结果覆盖当前阅读。摘要本地原子保存为 0600 文件，带 provider/model/date/sourceRevision；源版本改变时标过期，由用户决定重新生成。

### 本阶段验证与边界

- 最终定向测试：8 项 XCTest 通过；Swift Testing 的 17 项常规测试通过，另两项付费集成测试默认跳过。覆盖分组、结果 ID 定位、错误计数、Meta 搜索显现、Thinking 排除、Markdown 块与代码内容、材料预算和来源压缩摘要保留；原有完成通知取消/期限/请求格式回归通过。证据：`.scratch/wake-reading-summary/tests.log`。
- 另外显式运行真实 Qwen 集成测试，使用一份真实 Wake 研究会话副本及已有配置 `qwen3.8-flash`，27.3 秒返回 1,688 UTF-8 字节摘要，保存后重读一致。该样本材料为 52/52 readable records，因解析/片段限制明确标为 partial。证据：`.scratch/wake-reading-summary/real-summary.log`。
- 隔离 Release Mac 实例读取6份真实来源副本，另用1份明确标记的合成来源覆盖稀有显示状态。GUI 已检查用户气泡、助手标题/代码块/表格、Thinking 默认折叠、2个工具及1个失败、配对输出、压缩提示、隐藏 Meta/独立 Thinking、工具结果搜索自动展开、Meta 显式搜索、摘要缺配置提示、真实摘要缓存加载、来源变更后过期提示。6份来源内容 SHA-256 均不变；仅在隔离副本上 touch 验证过期。证据：`.scratch/wake-reading-summary/runtime-evidence.json`。
- 真实 provider 请求走核心集成测试，GUI 使用该请求保存的真实摘要；隔离 GUI 的独立 keychain 没有配置真实密钥，因此未宣称完成“GUI 点击到真实 provider”这一整条已配置密钥的验收。UI 缺配置路径已实测。
- Release 构建通过，隔离实例已退出，未替换日常应用。未提交、推送、部署或发布；没有扩展到跨机、更多 agent 或图片阅读能力。

### 本阶段最终评审

**Standards：** 直接检查新解析/投影、搜索原 ID 映射、取消与来源版本校验、HTTP 默认参数兼容、私有持久化及旧缓存升级。修复了 Codex 来源压缩摘要因 system 角色被摘要材料过滤的问题；当前范围未发现其余阻断缺陷。网络及界面验收的分层边界如上。

**Spec：** 用户批准的六项显示行为及主动会话摘要均已实现；索引/收藏/归档和实时完成通知的边界保留。摘要覆盖有限材料，不承诺整份超大日志或全部历史库都进入模型；更换来源后会显示过期，而不会自动产生新请求。使用说明见 `docs/session-history.md`，领域定义见 `CONTEXT.md`。

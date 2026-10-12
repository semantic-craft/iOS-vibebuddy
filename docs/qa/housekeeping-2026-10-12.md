# 项目收尾与清理 — 2026-10-12

后续当前状态：[暂不实施计划收尾](deferred-plan-closeout-2026-10-12.md) 关闭商店/Web 11 票，SQLite 移为观察；正式开放施工票为 0。本文“保留 12 票/21 票”等措辞是对应历史收尾时点，不代表当前队列。


后续状态：[自动补验与结案](acceptance-closeout-2026-10-12.md) 已关闭 9 票、保留 12 票；本文各条件和“21 票保留”措辞是第一轮时点的历史核对结果，闭票以新版记录为准。

核对基线：`9bf62eecfaa96b59d0b494814ff9f51ce55fc445`（main 与 origin/main 同步）。21 份开放工单全部按原验收条目登记如下。**历史证据已核对**指读取已有 QA 和主分支实现/合并记录，不代表本次重新运行整套验收；**部分 / 未核实**不能勾选整个条件，21 票均继续保留。代码存在、开放状态、当前发布版本三者不互相替代。

本次不补做所有真机/收费调用，也不启动延后的 Mac 商店开发。当前 Cursor Mac/iPhone 零会话验收与正式版本记录见 [连接代理 QA](connected-agent-roster-2026-10-12.md)、[发布流程 QA](asc-release-workflow-2026-10-12.md)；它们不覆盖 Gemini 实听、MiniMax 音频路由、Grok Build 重载或商店沙盒。

## 清理与保留

- 开始时工作区无未提交修改、开放 PR 为 0、Git 只有主工作树。vibebuddy-mcp 同项目实时状态未发现 peer；进程核对仍保留安装应用、共享 WDA 与桌面控制内核，不终止它们。
- 删除三个已合并远端分支（PR #353/#354/#355），各分支树与对应合并树相等；删除这三个本地分支、Cursor 原始分支及落后且已进入 origin/gh-pages 的本地 gh-pages。Cursor 代码与 PR #356 合并树相等，仅 QA 多出准确的基线说明。fetch/prune 清除五个已删远端分支的失效引用。
- 保留 `codex/prototype-antigravity-20261004` / `55ad3f97`：研究 PROTOTYPE.md 和 Antigravity QA 明确引用它，含 main 没有的可重放探针。保留 origin/gh-pages 与全部发布标签、在线 DMG/delta/feed，不改发布更新文件。
- 清理未跟踪的闲置 Mac/iOS 编译目录、Kit 编译缓存、四个 deploy 候选及四个日语测试应用；删除前确认没有打开文件、没有 xcarchive/xcresult、没有 Git 跟踪内容。路径与已分配空间见下方清单。
- 保留最新 iPhone 1.3.38/73 xcarchive 与 export IPA（提审待处理），旧签名归档及现有 QA 音频/日志/xcresult/安装回执保留作验收依据；不为清理另建备份。保留 Mac .build：其中 vibebuddy-mcp 是当前本机可用工程入口，未将它当作纯缓存整体删除。保留 .envrc、凭据、本机配置、用户数据与所有有效 ADR/研究。
- 未发现可直接判为无用的未合并代码或历史决策，未按年代删除文档。两份已完成会话已读取最终结果后归档：“20261011-方案设计｜Grok Bot 完成事件与离线补收”、“20261010-等待审核｜日语摘要与四家音色”。当前收尾会话保留。可见最近 50 个会话是本次对话核查边界，未宣称遍历所有历史会话。

## 工单逐项核对

<a id="agent-engineering-contract-01"></a>

### [agent-engineering-contract/01](acceptance-closeout-2026-10-12.md#agent-engineering-contract-01)

主分支：tools/check.py、tools/redeploy-mac.sh、tools/lib/install-mac-app.sh；PR #350 已进入基线。

证据：[既有记录](agent-engineering-contract-20261005.md)。检查与隔离计划有历史证据；本次 Cursor 发布有实际安装，但不能覆盖全部语音、恢复及用户验收。

| 条件 | 核对结果与边界 |
|---|---|
| 1. Synthetic：保留JSON-RPC framing/isError与CLI0/1/2；安装plan不写Application/端口/登录配置，skip/limitation可解析。 | 历史证据已核对：JSON framing/isError、CLI 0/1/2、只读 plan 与 skip 消费回归通过；本次未重跑该整套检查。 |
| 2. Real service / actual entry：隔离工程检查输出可消费；安装前只读识别共享App peer，占用时继续独立工作且保留未安装状态。 | 历史证据已核对：实际 CLI 只读计划识别隔离 foreign peer，blocked 且无写入；未把当前无 peer 当作共享安装许可。 |
| 3. Product：后续指定安装从计划到回执可核验；实机/手机/语音未验不能标通过，纯读status不强加dry-run。 | 部分：本次 Cursor Mac 安装/Sparkle 和物理 iPhone 有独立记录；生产恢复、语音及完整用户接受仍未核实，不能整项勾选。 |
| 4. 回填受验提交、实际命令/结果、产物身份/hash、未运行项及不含个人home路径的证据指针；完整本地证据由owner保留。代码、测试、合并、部署、产品验收和用户接受分别报告。 | 历史证据已核对：PR #350 exact-head、命令、hash、未运行项、脱敏指针可追溯；后续发布回执不改写原验证基线。 |

<a id="agent-integration-2026-09-07"></a>

### [agent-integration-2026-09/07](../planning/backlog/agent-integration-2026-09/rollout-sqlite-observation.md)

主分支：VibeBuddyMac/Sources/VibeBuddyMacCore/CodexRolloutMonitor.swift 与 CodexAppServerMonitor.swift；现行主源仍按 ADR-0011。

证据：[既有记录](../codex-integration.md)。未复现 rollout 停写触发条件；SQLite 降级与 queue 兜底未核实，观察项保留。

| 条件 | 核对结果与边界 |
|---|---|
| 1. SQLite 存在且 rollout 停止增长的触发判断及观测健康说明 | 未核实：未复现 rollout 停写触发条件；SQLite 降级与 queue 兜底未核实，观察项保留。 |
| 2. app-server 证据过期时 queue --thread steer 兜底 | 未核实：未复现 rollout 停写触发条件；SQLite 降级与 queue 兜底未核实，观察项保留。 |

<a id="antigravity-monitor-05"></a>

### [antigravity-monitor/05](acceptance-closeout-2026-10-12.md#antigravity-monitor-05)

主分支：现行 Antigravity monitor 与 SoundPolicy；已有 R2 漏提醒、R3 送达的真实证据。

证据：[既有记录](antigravity-monitor-20261004.md)。未重放同会话紧接新问题；未定位为 APNs/Watch 故障，保留 needs-triage。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 重放真实“问题→回答→完成→紧接新问题”并记录 monitor 与 SoundPolicy 收到的状态/turn 边界，确认中间 working/done 是否被轮询或快照合并。 | 未核实：未重放同会话紧接新问题；未定位为 APNs/Watch 故障，保留 needs-triage。 |
| 2. 区分现行提醒去重策略与新轮次漏提醒；目前尚未定位原因，不推断为 APNs 或手表故障。 | 未核实：未重放同会话紧接新问题；未定位为 APNs/Watch 故障，保留 needs-triage。 |
| 3. 如确认缺陷，以该时序留下可重放回归检查，并验证新轮次提醒一次、同一等待不重复提醒。 | 未核实：未重放同会话紧接新问题；未定位为 APNs/Watch 故障，保留 needs-triage。 |

<a id="gemini-provider-suite-01"></a>

### [gemini-provider-suite/01](acceptance-closeout-2026-10-12.md#gemini-provider-suite-01)

主分支：VibeBuddyKit/Sources/VibeBuddyKit/GeminiSpeechSynthesizer.swift、GeminiRealtimeSession.swift；Mac CompletionSummaryService/ContentPresentationService；PR #346 已进入基线。

证据：[既有记录](gemini-suite-20261004.md)。三用途已实现。日语 QA 补充了 Gemini Mac 试听和四家音频解码，手机实际结果播放使用豆包；不能据此关闭 Gemini 两端实听、连续队列及实时操作验收。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 两端相应设置能保存/读取 Gemini 凭据与摘要用途配置；按既有职责由来源 Mac 生成摘要，手机不新增另一套摘要服务或同步 Key。 | 部分：配置实现和隔离检查已合并；两端完整保存/重启、配对手机凭据归属运行验收未核实。 |
| 2. 用隔离设置/凭据回放旧退役迁移场景，证明新配置不被删；已有显式选择保留，功能不会自动启用，缺 Key 或旧型号不可用时反馈清楚。 | 部分：用途配置/偏好回归有记录；完整旧退役配置迁移与错误反馈真实流程未核实。 |
| 3. 真实完成轮次在 Mac 和配对手机上显示正确摘要，遵循语言/内容风格、180 字通知与 900 字朗读呈现契约；只展示最终正文。 | 部分：真实 Mac 呈现及日语结果生成有证据；配对手机 Gemini 摘要、全部语言/风格及字符契约联合流程未核实。 |
| 4. 通知 12 秒决策时限、取消、生成期间新轮次及配置变化继续生效；失效结果不发布，无静默供应商/模型回退。 | 部分：主分支 12 秒时限、取消 worker 与过期门禁存在并有定向回归；真实新轮次/配置变化全过程未核实。 |
| 5. 同批经授权的真实样本比较 `gemini-3.5-flash-lite` 与 `gemini-3.8-flash`，记录耗时、用量、超时和事实准确性，按 PRD 规则落实默认值，仍允许用户修改。 | 历史证据已核对：授权同批模型比较、超长拒绝、耗时与用量记录支持默认 3.5 Flash-Lite，不再重复付费比较。 |
| 6. 固定官方 SDK 版本做必要的协议对照；普通用户沿用 Keychain，开发凭据显式注入，错误和日志不回显 Key/带 Key URL/完整正文。 | 历史证据已核对：固定 google-genai 2.25.0 协议对照及开发注入边界；未读取凭据。 |
| 7. 受影响配置、摘要/内容呈现回归检查及 Mac/iOS 构建通过；真实摘要验收证据明确来源、轮次、模型与结果。 | 部分：合并版本回归/两端构建有证据；当前主分支未重建，配对手机真实轮次与重启仍未核实。 |

<a id="gemini-provider-suite-02"></a>

### [gemini-provider-suite/02](acceptance-closeout-2026-10-12.md#gemini-provider-suite-02)

主分支：VibeBuddyKit/Sources/VibeBuddyKit/GeminiSpeechSynthesizer.swift、GeminiRealtimeSession.swift；Mac CompletionSummaryService/ContentPresentationService；PR #346 已进入基线。

证据：[既有记录](gemini-suite-20261004.md)。三用途已实现。日语 QA 补充了 Gemini Mac 试听和四家音频解码，手机实际结果播放使用豆包；不能据此关闭 Gemini 两端实听、连续队列及实时操作验收。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 两端能选择 Gemini TTS、保存模型/声音/风格并试听；默认使用 `gemini-3.8-flash-lite-tts`，模型可编辑。 | 部分：目录/设置/生成和 Mac Gemini 日语试听完成有证据；手机 Gemini 全设置与试听未核实。 |
| 2. 跟随 Gemini 摘要时可自动解析到 Gemini TTS；固定其他供应商时不受摘要切换影响，无 Key/供应商不可用时不暗中切换。 | 部分：用途/跟随固定配置已有回归；两端实际切换与不可用反馈未核实。 |
| 3. Mac/iPhone 均朗读真实结果，中文、英文标识符和数字可听清，正文事实不被增删；需要比较音色质量时按 PRD 对比 Flash TTS 并记录依据。 | 部分：Gemini 真实长 WAV 完整解码与 Mac 日语试听有记录；两端中文/标识符/数字人耳听感未核实，豆包手机播放不替代。 |
| 4. 暂停、停止、跳过、重播和连续队列遵循现有行为；已取消的合成结果不进入播放队列，听取不改变已读状态。 | 部分：队列与取消回归存在；Gemini 两端真实暂停/停止/跳过/重播/连续队列未核实。 |
| 5. 已有通话可暂停朗读，手动队列恢复沿用现有规则；Gemini 与 Gemini 的完整联动留到 GEM-04。 | 部分：既有通话暂停协调回归可复用；Gemini 设备朗读与通话互斥未核实。 |
| 6. 空/错误 MIME/过大音频、拒绝、限流与网络错误有界处理且可见；固定版本官方 SDK 对照产物与产品音频均记录格式。 | 历史证据已核对：有界解码失败处理、SDK/产品 WAV 记录及分段修复红绿证据。 |
| 7. 受影响合成/队列测试与两端构建通过；分别记录生成音频、播放器完成、设备实听证据。 | 部分：定向测试与修复后构建有记录；人耳实听与两端播放器联合证明未核实。 |

<a id="gemini-provider-suite-03"></a>

### [gemini-provider-suite/03](acceptance-closeout-2026-10-12.md#gemini-provider-suite-03)

主分支：VibeBuddyKit/Sources/VibeBuddyKit/GeminiSpeechSynthesizer.swift、GeminiRealtimeSession.swift；Mac CompletionSummaryService/ContentPresentationService；PR #346 已进入基线。

证据：[既有记录](gemini-suite-20261004.md)。三用途已实现。日语 QA 补充了 Gemini Mac 试听和四家音频解码，手机实际结果播放使用豆包；不能据此关闭 Gemini 两端实听、连续队列及实时操作验收。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 两端能保存实时模型/声音并建立通话；setup 确认后才显示连接就绪。设置检查不打开麦克风、不加载任务上下文或工具。 | 部分：主分支 setupComplete 就绪门禁与 Live 设置存在；两端设备麦克风通话建立未核实。 |
| 2. 两端均完成真实音频往返和连续两轮问答，双方转写与轮次处理正确；一次 response 完成不关闭整通电话。 | 部分：SDK/原生 Live 协议连续轮次有记录；两端真实音频往返及连续两轮设备问答未核实。 |
| 3. 语音查询读取当前真实任务；在明确授权的可控任务上完成现有操作，应用层确认后才反馈成功，不声称 agent 已完成任务。 | 部分：工具/协调器回执检查存在；真实指定任务的设备查询与受控操作未核实。 |
| 4. 目标不明确/过期时沿用原核验拒绝；取消、打断后的旧调用和迟到回包不再执行，不重试有副作用动作。 | 部分：目标核验与取消回归存在；设备迟到回包与打断真实操作未核实。 |
| 5. 打断、挂断关闭音频与会话；结束通话工具先满足原回执交付约定，晚到音频不重新播放。 | 部分：挂断/取消/晚到音频回归存在；设备音频关闭与结束回执体验未核实。 |
| 6. GoAway 预告与实际断开分开处理；确认供应商时限才显示正常到顶，网络/认证/配额故障仍为失败；重拨创建新通话。 | 部分：主分支区分 GoAway 与 cleanClose；实际供应商长时限、失败分类与新通话重拨未核实。 |
| 7. 保留现有通话暂停朗读机制，Gemini TTS 尚未交付时用已有朗读供应商验证；不实现透明会话恢复。 | 部分：既有暂停协调器回归有证据；设备朗读互斥未核实，不引入透明恢复。 |
| 8. 关键协议/协调器回归、两端构建和设备短通话通过；真实供应商长时限未测时单列，不用协议重放替代实测声明。 | 部分：45 项协议/协调器等及增量检查、两端构建有记录；设备短通话及长时限未核实。 |

<a id="gemini-provider-suite-04"></a>

### [gemini-provider-suite/04](acceptance-closeout-2026-10-12.md#gemini-provider-suite-04)

主分支：VibeBuddyKit/Sources/VibeBuddyKit/GeminiSpeechSynthesizer.swift、GeminiRealtimeSession.swift；Mac CompletionSummaryService/ContentPresentationService；PR #346 已进入基线。

证据：[既有记录](gemini-suite-20261004.md)。三用途已实现。日语 QA 补充了 Gemini Mac 试听和四家音频解码，手机实际结果播放使用豆包；不能据此关闭 Gemini 两端实听、连续队列及实时操作验收。

| 条件 | 核对结果与边界 |
|---|---|
| 1. Mac/iPhone 走完用户确认的三条真实流程：完成结果 → 摘要；指定结果 → 朗读；实时通话 → 查询/受控操作 → 回执。 | 未核实：两端三用途全部真实流程；已有日语/豆包手机播放只覆盖其中一部分。 |
| 2. Gemini 朗读期间启动 Gemini 通话，播报按现有规则暂停；挂断后手动队列不擅自恢复；旧音频/工具结果不串入新轮次。 | 未核实：Gemini TTS + Gemini Live 两端同时使用、手动恢复与迟到结果隔离设备流程。 |
| 3. 三用途独立切换、朗读跟随与固定、两端重启后设置保持、未配置不自动启用等联合场景通过；原千问等配置不被改变。 | 部分：用途配置与凭据回归存在；两端重启、完整切换和旧配置保持联合验收未核实。 |
| 4. 手机继续使用来源 Mac 的证据与内容风格；断线/过期结果不生成错误摘要，不把听到结果视为已读或完成验收。 | 部分：来源/内容呈现与未读边界有回归；失联与过期设备场景未核实。 |
| 5. 修复本次联合流程暴露的缺陷，并只重跑受影响检查；复用 01–03 已有有效证据，不无理由重跑全部测试或模型比较。 | 部分：WAV 分段缺陷已修复并复验；尚未执行完整设备联合验收，不能判定全部集成缺陷已清除。 |
| 6. 汇总实际代码版本、默认模型及 SDK 版本、构建、真实调用、设备实听、错误恢复、已测/未测供应商时限；不能将设备/凭据缺口标为通过。 | 部分：QA 汇总源提交、SDK、模型、构建、真实调用与缺口；用户实听/设备控制和供应商长时限未核实。 |
| 7. 对最终差异做规范与 PRD 两轴评审，处理有效发现；领域文档描述最终行为且保留历史移除记录。 | 历史证据已核对：两轴评审与 WAV 修复复核见 QA；本次文档差异另按现行 AGY 门槛评审。 |
| 8. 所有 PRD 验收门槛满足才宣告整套交付；安装、发布、提交和用户最终体验确认与代码验证分别记载。 | 未核实：PRD 全部门槛与用户体验确认；保持开放。 |

<a id="grok-build-onboarding-01"></a>

### [grok-build-onboarding/01](acceptance-closeout-2026-10-12.md#grok-build-onboarding-01)

主分支：现行 GrokBuild monitor/HookInstaller 与 Mac Agent 接入 UI；另核对 grok-mobile-1.3.34.md、grok-ios-1.3.34-distribution.md。

证据：[既有记录](grok-mac-1.3.42.md)。旧提审版本记录是历史状态；本次发布版本已更新。真实 Grok 终端 /hooks → r 后的事件及手机对应画面仍未核实；Grok Bot 不代替 Grok Build。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 复现原场景：账户额度开启、Grok 已运行、观测 hooks 缺失；界面明确提示尚未接入，并在同一处提供开启操作。 | 历史部分：真实发现项目/等待接入记录已核对；原完整额度+缺 hooks 场景未在当前版本重放。 |
| 2. 通过 Computer Use 开启「监控 Grok Build」，无需诊断页或命令行安装；配置写入成功后，已有真实会话可见，未收到事件时明确标记等待接入。 | 历史部分：安装与发现 UI 已记录；不把配置存在当成真实事件已接入。 |
| 3. 按界面步骤完成必要的 Grok 重载，使用真实 Grok 事件验证状态更新和卡片去重；核对 `/snapshot` 及 `/ws` 下游数据与 Mac 界面一致。 | 未核实：真实终端 /hooks → r 后事件、去重、snapshot/ws 与 UI 对照仍是关键缺口。 |
| 4. 检查配置失败时能看到原因并重试；检查开启后暂无会话时不会误报失败或已连接。 | 部分：配置/等待接入回归有记录；真实失败后重试全过程未核实。 |
| 5. 关闭后重启仍关闭；额度采集保持原设置。已有安装配置及主动卸载记录的迁移行为符合上文。 | 部分：关闭与迁移回归有记录；当前安装版重启与额度独立保持未核实。 |
| 6. 为“无 hooks 的活跃会话不可见”和配置成功不等于收到事件保留少量可重放回归检查；运行受影响 Swift 测试与 Mac 构建，不扩张测试矩阵。 | 历史证据已核对：已合并的定向 Swift 回归与 Mac 构建；本次未重复构建。 |
| 7. 使用 `verify-vibebuddy` 的隔离环境及适用 GUI 配置，核对真实 Grok 数据与中英文 AX 操作。真实配置写入仅在明确授权的环境中执行；缺少运行条件时报告具体缺口，不以静态检查代替端到端结果。 | 部分：隔离/UI 与真实发现证据已记录；终端重载后实时事件和手机界面仍未核实。 |
| 8. 更新用户文档中的接入路径，删除与新交互冲突的“必须去维护手动安装”说明；诊断页仍可保留高级修复工具。 | 历史证据已核对：用户接入文档与现行安装入口已更新；高级诊断保留。 |

<a id="ios-companion-parity-06"></a>

### [ios-companion-parity/06](acceptance-closeout-2026-10-12.md#ios-companion-parity-06)

主分支：VibeBuddyApp/Sources 的语音、历史及终端实现；原 01–05 已合并。

证据：[既有记录](../planning/backlog/ios-companion-parity/acceptance.md)。模拟器、真实合成及协议证据保持；物理 MiniMax 音色耳听/路由/VoiceOver 与拥有目标及多页终端的真实 app-server 仍未核实。Cursor 零会话手机验收不覆盖这些条件。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 共享库、Mac 核心全套测试，Mac / iOS 构建与 iOS 模拟器测试。 | 历史证据已核对：共享库/Mac 测试、两端构建及 iOS 模拟器测试记录。 |
| 2. 隔离 daemon 使用真实 Codex 会话数据，鉴权、来源边界与本地历史读取。 | 历史证据已核对：隔离 daemon 真实 Codex 数据、鉴权与历史读取记录。 |
| 3. Standards / Spec 分别评审，修复暂停恢复与终端分页覆盖问题。 | 历史证据已核对：两轴评审与暂停/终端分页修复记录。 |
| 4. 原生模拟器 UI E2E：中文朗读设置、独立语言选择、密钥编辑取消、真实历史回退与最大字号操作可达；截图核验。 | 历史证据已核对：原生模拟器 UI E2E 与截图覆盖列出的设置/历史/字号；不当作实体体验。 |
| 5. 真实 MiniMax 四种风格合成并进入 iOS 原生播放器；最终音频 / 网络定向复验 12/12，UI E2E 2/2。 | 历史证据已核对：真实 MiniMax 四风格合成及播放器检查；不当作人耳听感。 |
| 6. 在 iPhone 安全输入本机 MiniMax 密钥，试听各风格，耳听核对音色；检查来电、耳机拔出和 VoiceOver 共存。自动化回归不代替耳听与实物音频路由。 | 未核实：实体 MiniMax 四风格听感、来电/拔耳机/VoiceOver 共存；日语音频解码不替代。 |
| 7. 在拥有真实目标及后台终端的 Codex app-server 上核验目标数值与多页终端；本轮隔离 app-server 未持有原线程运行时及完整原生项目索引。 | 未核实：持有真实目标及后台终端的 app-server 目标数值/多页终端验收。 |

<a id="mac-app-store-09"></a>

### [mac-app-store/09](deferred-plan-closeout-2026-10-12.md#mac-app-store-09)

主分支：VibeBuddyMacApp/project.yml 仅有直接版 application target，依赖 Sparkle；main 无商店 target。

证据：[既有记录](../planning/backlog/mac-app-store/CHECKLIST.md)。09–18 全部保留并延后。直接版或 iPhone App Store 发布不能代替 Mac 商店沙盒的签名、容器、Pairing、原生安装器及审批验收。历史探针/决策保留，未启动商店开发。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 实际 Apple Development 签名包含 app-sandbox、网络入站/出站、音频输入及用户选择目录所需权限，无 temporary-exception；进程 home 位于独立容器。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 2. Daemon 默认监听 9880，并拒绝占用 9876/9877；真实 iPhone 扫码 Pairing 成功并收到快照，证据不暴露二维码中的 bearer token。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 3. 商店 bundle 无 Sparkle，自更新菜单不出现；直接版隔离构建通过，原签名设置和更新入口保持。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 4. 首次启动不连接 app-server socket、不启动外部 CLI 或未授权目录扫描；不提供能执行 Dispatch、Attach 或终端注入的入口。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 5. 局域网用途描述存在，记录首次 Pairing 的实际提示结果；若系统未弹提示，附触发条件和原因，未获验收措辞裁定前不将该项标通过。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 6. 保留最小 UI、监听、签名与真实 Pairing 证据；不以构建成功替代手机验收。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |

<a id="mac-app-store-10"></a>

### [mac-app-store/10](deferred-plan-closeout-2026-10-12.md#mac-app-store-10)

主分支：VibeBuddyMacApp/project.yml 仅有直接版 application target，依赖 Sparkle；main 无商店 target。

证据：[既有记录](../planning/backlog/mac-app-store/CHECKLIST.md)。09–18 全部保留并延后。直接版或 iPhone App Store 发布不能代替 Mac 商店沙盒的签名、容器、Pairing、原生安装器及审批验收。历史探针/决策保留，未启动商店开发。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 商店 bearer token 权限为 0600，重启前后在内存比较相等，手机使用原 Pairing 重新连接成功。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 2. 设备注册、Missed、通知投递、LifecycleJournal、用量缓存、注意力覆盖和 always-allow 数据按各功能实际写入容器；重启读取符合其原有保留规则。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 3. 惰性数据通过触发对应行为验证；尚未触发的文件如实记录，不能仅创建空文件充当持久化证据。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 4. 直接版存储位置与读写行为不变；隔离两实例各自产生测试数据，互不覆盖或读取对方数据。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 5. 外部 Claude 后台 jobs 不归类为自有数据；商店不启用后台任务索引读取或 Attach。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 6. 只记录根归属、权限和相等结论，不输出 token 或用户目录树。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |

<a id="mac-app-store-11"></a>

### [mac-app-store/11](deferred-plan-closeout-2026-10-12.md#mac-app-store-11)

主分支：VibeBuddyMacApp/project.yml 仅有直接版 application target，依赖 Sparkle；main 无商店 target。

证据：[既有记录](../planning/backlog/mac-app-store/CHECKLIST.md)。09–18 全部保留并延后。直接版或 iPhone App Store 发布不能代替 Mac 商店沙盒的签名、容器、Pairing、原生安装器及审批验收。历史探针/决策保留，未启动商店开发。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 系统对话框可选择隐藏目录和任意隔离配置目录，界面有路径输入/显示隐藏项引导；不以单文件授权替代父目录权限。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 2. 分别授权两目录并重启应用，仍能访问已授权位置，不重复弹选择对话框。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 3. 跳过一项只影响依赖它的功能；Settings 与 ObservationHealth 区分未授权、未配置及健康状态，不显示虚假的无任务或全部完成。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 4. 移动后若 bookmark 仍有效则继续访问并更新持久状态；实际拒绝、丢失或撤销后停止访问、显示恢复入口，重新授权可恢复。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 5. 在授权目录内完成无害测试文件的创建、同目录原子替换与本次文件清理，证明安装所需访问范围；不修改真实配置。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 6. 授权释放与长期访问生命周期成对；直接版路径不变，日志不记录目录内容。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |

<a id="mac-app-store-12"></a>

### [mac-app-store/12](deferred-plan-closeout-2026-10-12.md#mac-app-store-12)

主分支：VibeBuddyMacApp/project.yml 仅有直接版 application target，依赖 Sparkle；main 无商店 target。

证据：[既有记录](../planning/backlog/mac-app-store/CHECKLIST.md)。09–18 全部保留并延后。直接版或 iPhone App Store 发布不能代替 Mac 商店沙盒的签名、容器、Pairing、原生安装器及审批验收。历史探针/决策保留，未启动商店开发。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 安装、重复安装、修复、卸载均可从 Settings 完成，提供成功或失败状态；应用不 spawn CLI 或 Python。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 2. 与受控 Python 样例对照，事件、matcher、参数、async、timeout 和已选审批门语义一致；混合组内他人 handler、其它设置和完整原 Status line 对象被保留。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 3. 审批默认 PermissionRequest，保留 AskUserQuestion 专用问题门；从样本版本提示低于当前最低版本 2.1.257 的用户升级，无样本/不可解析显示未知，不自行切回旧门。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 4. 真实隔离 Claude 执行安装生成的 exec-form 和 shell-string 命令后，事件通过认证到达 9880；Status line sample 丰富已有 Session，不创建 Session 或推进三态。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 5. 每条命令引用 bundle 资源并使用商店端口、token 文件与 support 位置；Claude 配置与日志无 token 原值，共享脚本不变。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 6. 写前备份、失败保持原配置；坏 JSON 不覆盖；卸载还原原 Status line。旧 wrapper 原备份无法安全取得时保持原配置并显示恢复入口。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 7. app 更新位置不变时命令继续有效，移动后显示修复；重复安装不递归包装。直接版安装入口和行为不变。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |

<a id="mac-app-store-13"></a>

### [mac-app-store/13](deferred-plan-closeout-2026-10-12.md#mac-app-store-13)

主分支：VibeBuddyMacApp/project.yml 仅有直接版 application target，依赖 Sparkle；main 无商店 target。

证据：[既有记录](../planning/backlog/mac-app-store/CHECKLIST.md)。09–18 全部保留并延后。直接版或 iPhone App Store 发布不能代替 Mac 商店沙盒的签名、容器、Pairing、原生安装器及审批验收。历史探针/决策保留，未启动商店开发。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 外部进程读取商店容器 token 与原 Status line 备份的 A1 结果有独立证据；只记录读取成功/非空/权限及真实认证结果，不输出内容或将非 401 当成功。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 2. 真实 iPhone 与隔离商店实例配对，批准、拒绝、AskUserQuestion 回答各一次往返；隔离动作的实际后果与决定一致，不以卡片或 HTTP 回包代替执行证据。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 3. Presence 为 away 或显式 phone-first 时远程放行成立；本地 Presence 的 read-only card 路径单独验证，不与远程放行混淆。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 4. Mac 卡片先答后手机撤卡，重复/晚到响应不会二次执行同一请求。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 5. 应用退出后再触发审批，Claude 返回自身提示；连接拒绝与无回答的有界等待分别记录，不能永久卡死，也不将所有故障承诺为一秒。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 6. Status line sample 填充既有 Session 名称和上下文，Live usage feed 收到可用样本；无凭空新建 Session。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 7. 记录脱敏命令、结果、时间及截图定位，全部使用隔离配置，未修改真实代理配置或运行中的直接版。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |

<a id="mac-app-store-14"></a>

### [mac-app-store/14](deferred-plan-closeout-2026-10-12.md#mac-app-store-14)

主分支：VibeBuddyMacApp/project.yml 仅有直接版 application target，依赖 Sparkle；main 无商店 target。

证据：[既有记录](../planning/backlog/mac-app-store/CHECKLIST.md)。09–18 全部保留并延后。直接版或 iPhone App Store 发布不能代替 Mac 商店沙盒的签名、容器、Pairing、原生安装器及审批验收。历史探针/决策保留，未启动商店开发。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 每个已列 CLI 在隔离目录完成安装、重复安装、卸载与用户配置还原；事件及参数遵循对应安装器语义，不将不同宿主 schema 强行统一。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 2. Codex 保持同步限时 Hook、PermissionRequest 门和既有审批选择，notify 不变；界面明确要求新会话重新信任，且不读取或伪造信任状态。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 3. 真实隔离 Codex CLI 请求经 iPhone 批准后按预期执行；至少另一 CLI 的真实生命周期进入 Daemon 并改变三态。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 4. OpenCode 从 bundle 内插件实际加载并将事件送到正确商店端口，正确取得认证且可卸载恢复；不复制插件代码到共享位置，不另装 bridge。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 5. 命令形状经未修改直接版的识别方式验证；不因环境注入产生无法识别的重复 Hook，双向完整接管另由 17 验收。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 6. Qwen 保留既有 native-http 认证例外但不向日志/截图暴露 query token；token 轮换和端口变化按真实契约处理。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 7. 安装成功与宿主确实执行分开记录；Antigravity 等宿主限制如实显示，不把配置存在视为生命周期通过。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |

<a id="mac-app-store-15"></a>

### [mac-app-store/15](deferred-plan-closeout-2026-10-12.md#mac-app-store-15)

主分支：VibeBuddyMacApp/project.yml 仅有直接版 application target，依赖 Sparkle；main 无商店 target。

证据：[既有记录](../planning/backlog/mac-app-store/CHECKLIST.md)。09–18 全部保留并延后。直接版或 iPhone App Store 发布不能代替 Mac 商店沙盒的签名、容器、Pairing、原生安装器及审批验收。历史探针/决策保留，未启动商店开发。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 真实隔离 Desktop Session 的 rollout 信号绑定到正确 Session，`task_started` / `task_complete` / `turn_aborted` / `item_completed` 驱动三态更新；未观察到的状态不猜测、不补齐。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 2. Desktop Session 在手机与 Mac 上均为只读：无 approve / answer / Steer / continue 入口，通知动作、语音与服务端行为一致；禁用不得破坏 13 已通过的 Claude 审批与问答。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 3. 商店不启动 app-server、socket 或 CLI fallback，Settings 不显示相应开关；直接版仍保持 ADR-0011 主源行为与 Desktop 审批能力。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 4. 撤销目录授权停止观察并显示恢复入口，重新授权可恢复；未知的进程身份不能误报 Abandoned、无任务或 healthy。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 5. Codex 来源诊断只呈现适用的 Hook、rollout、Status line 信号，并明确告知商店版不观察 Desktop 审批等待；Jump 返回已有 activatedApp 语义并实际激活宿主。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 6. 不实现等待提醒，也不用超时、静默或进程探针推断等待。若 Codex 将来开始持久化审批事件，另开新票，不在本票内偷加。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |

<a id="mac-app-store-16"></a>

### [mac-app-store/16](deferred-plan-closeout-2026-10-12.md#mac-app-store-16)

主分支：VibeBuddyMacApp/project.yml 仅有直接版 application target，依赖 Sparkle；main 无商店 target。

证据：[既有记录](../planning/backlog/mac-app-store/CHECKLIST.md)。09–18 全部保留并延后。直接版或 iPhone App Store 发布不能代替 Mac 商店沙盒的签名、容器、Pairing、原生安装器及审批验收。历史探针/决策保留，未启动商店开发。

| 条件 | 核对结果与边界 |
|---|---|
| 1. iPhone 连接商店版时快照 dispatchAgents 为空且无 New task；连接支持 Dispatch 的直接版时仍可用，Mac 自身入口同步受限。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 2. 禁用能力在 Mac、iPhone、语音及服务端均不能执行，包括 Attach、终端注入、Steer/continue、精确定位和外部采集；不能只隐藏按钮。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 3. Jump 实际将对应终端或宿主拉到前台，复用 activatedApp 文案，不新增线协议或承诺精确标签页。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 4. Claude 额度随 Live usage feed 更新，缺失/过期显示真实未知或 stale；Codex 与无法采集的额度不显示假数据，不启动外部采集器。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 5. 有效 Hook 审批和 question relay 仍可往返，不能因禁用泛化控制而破坏 13 的能力。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 6. 保留/降级/隐藏清单逐项附依据；保留的通知、Glance、宠物、菜单栏、可选语音、登录启动和 Presence 进行受影响的实际验证，用途拒绝或不可用有明确反馈。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 7. 直接版行为不变；仅运行与本票影响有关的必要测试和真实流程。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |

<a id="mac-app-store-17"></a>

### [mac-app-store/17](deferred-plan-closeout-2026-10-12.md#mac-app-store-17)

主分支：VibeBuddyMacApp/project.yml 仅有直接版 application target，依赖 Sparkle；main 无商店 target。

证据：[既有记录](../planning/backlog/mac-app-store/CHECKLIST.md)。09–18 全部保留并延后。直接版或 iPhone App Store 发布不能代替 Mac 商店沙盒的签名、容器、Pairing、原生安装器及审批验收。历史探针/决策保留，未启动商店开发。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 隔离 direct→store 与 store→direct 安装均完成接管，当前配置仅有正确拥有者命令并显示提示，不新增运行时协商服务。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 2. 重复安装与旧拥有者卸载不会破坏当前配置；他人 Hook 和原 Status line 对象可恢复，无递归 wrapper。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 3. 两版隔离实例各有端口和 Pairing，避开 9876/9877；一次真实审批只由当前 Hook 拥有者收到并应答。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 4. 跨容器原命令备份不可取得时保留原配置并显示恢复入口，不凭空删除原 Status line。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 5. 使用虚构 Keychain 条目与隔离签名产物验证，只输出 OSStatus 和相等结果；不读取真实 key，不把虚构条目成功当旧凭据已继承。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 6. 若不能在当前边界内共享，说明原因并验证重输引导；需要修改直接版签名或迁移凭据时先提交具体候选，不自行执行。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 7. 直接版构建、签名与 key 读写逻辑保持不变，且所有已实现 CLI 的接管结果都有记录。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |

<a id="mac-app-store-18"></a>

### [mac-app-store/18](deferred-plan-closeout-2026-10-12.md#mac-app-store-18)

主分支：VibeBuddyMacApp/project.yml 仅有直接版 application target，依赖 Sparkle；main 无商店 target。

证据：[既有记录](../planning/backlog/mac-app-store/CHECKLIST.md)。09–18 全部保留并延后。直接版或 iPhone App Store 发布不能代替 Mac 商店沙盒的签名、容器、Pairing、原生安装器及审批验收。历史探针/决策保留，未启动商店开发。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 实际 Archive 的签名、app-sandbox 与资源检查通过，无 temporary-exception、Sparkle 或自更新入口；本地 Apple Development 验证与分发归档分别记录。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 2. 审核备注准确说明用户目录授权、必要配置修改、代码留在 bundle 内和无自更新；OpenCode 实现与描述一致，不声称已获合规确认。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 3. 隐私和用途说明覆盖实际麦克风、局域网、可选语音提供商及通知数据流；截图不泄露 token、key、用户目录内容或 Pairing QR。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 4. 在可用干净账户按 reviewer 步骤实际完成演示，记录结果；Demo Mode 不冒充真实 agent 审批证据。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 5. 账号平台及签名资料前置条件只读核实；缺 profile/账户等条件如实列明，不自动创建账户、联网申请签名资料或修改商店记录。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |
| 6. 上传、提交、审核结果留空；仅本地材料完成不得标发布或审核通过。 | 未核实：main 无商店 target，无本条要求的隔离商店签名/运行/设备证据；历史沙盒研究仅作设计依据。 |

<a id="mac-settings-usability-01"></a>

### [mac-settings-usability/01](acceptance-closeout-2026-10-12.md#mac-settings-usability-01)

主分支：VibeBuddyMacApp/Sources/SettingsView.swift、SettingsCredentials.swift 及 VoiceSettingsTab.swift；PR #336 与后续额度修复已进入基线。

证据：[既有记录](../planning/backlog/mac-settings-usability/acceptance-2026-10-01.md)。原始走查清单不是待重做实现；保留精确最小窗口、实际服务成功路径、手机/Watch 投递与相关用户体验缺口。

| 条件 | 核对结果与边界 |
|---|---|
| 1. S01：不依赖坐标或前一条文本即可区分每个开关、快捷键、服务商与修复动作；读出当前值、禁用状态和原因。更换界面语言后 ID 稳定。 | 部分：隔离中英文 AX/命名及重复菜单修复有证据；完整语言切换下所有控件运行验收未核实。 |
| 2. S02：编辑、取消、切页或关闭窗口都不偷偷覆盖旧值；保存成功才更新已保存状态；测试只使用明确的已保存配置；不在日志或工单记录密钥。既有 Keychain account 名不变。 | 历史证据已核对：隔离凭据草稿取消、保存失败/重试、显式移除及 account 保持；未操作真实 Key。 |
| 3. S03：从无密钥到完成配置能沿可见动作走通，不需猜跨页依赖；缺配置时不声称功能可用；取消配置不自动开启功能；不改变现有默认模型和朗读依赖规则。 | 部分：隔离缺配置、返回入口、不自动开启有证据；真实服务成功连接路径未核实。 |
| 4. S04：侧栏即可区分手机连接、Agent 监控接入、MCP 读取；同步更新入门文档中的路径，不改变命令和 MCP 契约。 | 历史证据已核对：设置侧栏/文档区分手机、Agent 与 MCP；MCP 打包未在该隔离 UI 构建中重验。 |
| 5. S05：寻找手机通知问题不会先遇到无关 hook 列表；投递失败仍可见，诊断信息无丢失；遵守 ADR-0025。 | 部分：手机投递区域/诊断入口隔离 UI 已核对；真实投递失败和设备显示未核实。 |
| 6. S06：不把偏好 on 显示成“通知正常”；准确说明审批/提问静默保留、其他会话提醒抑制、已开启额度提醒的例外；不修改投递决策及默认值。 | 部分：系统授权与偏好/静音说明及定向回归有证据；真实权限/专注模式/额度通知体验未核实。 |
| 7. S07：用户在 Agent 接入中能找到云端任务配置；用量来源开关不会被误认为关闭会话监控；复用已有配置与存储，不重复持有密钥。 | 历史证据已核对：Cursor 云端接入入口及用量来源说明已合并，保留原存储。 |
| 8. S08：估算费用与真实账单仍明确区分；原报表信息都能到达；无重复计算或第二份用量状态。 | 历史证据已核对：真实 rollout 副本、费用入口及全来源关闭报表可达记录；不混同实际账单。 |
| 9. S09：读到 App server 不可用不会理解为全部 Codex 监控停止；不将未知降格成正常，不伪造安装或修复成功；未安装与不可连接若共用文案需核对现有状态来源。 | 部分：权限原值展开 AX 崩溃已修复重放，状态说明已合并；当前主分支全部真实诊断修复流程未核实。 |
| 10. S10：语言切换不重置其他偏好；按钮和错误信息可读且可达；不靠增大窗口掩盖布局问题。搜索框、新导航框架和全设置迁移不在本轮范围。 | 部分：中英文重启/偏好/快捷键取消有证据；精确最小窗口、完整 Tab 顺序和中文换行未核实。 |

<a id="web-workbench-01"></a>

### [web-workbench/01](deferred-plan-closeout-2026-10-12.md#web-workbench-01)

主分支：main Snapshot 是现有可复用接口；工单要求跨项目契约与真实研究工作项，不是原生 Dashboard 本身。

证据：[既有记录](../planning/backlog/web-workbench/PRD.md)。Anamra 接口、论文只读投影、写入权威及第一条真实跨项目流程未核实；不扩大本次清理为新产品实施。

| 条件 | 核对结果与边界 |
|---|---|
| 1. 每个显示字段有真实来源或明确的缺失状态；样例脱敏且能追溯结构来源。 | 未核实：Anamra 接口、论文只读投影、写入权威及第一条真实跨项目流程未核实；不扩大本次清理为新产品实施。 |
| 2. 说明哪些接口可复用、哪些需新增，以及对现有原生客户端的影响。 | 未核实：Anamra 接口、论文只读投影、写入权威及第一条真实跨项目流程未核实；不扩大本次清理为新产品实施。 |
| 3. 明确身份过期、跨源不可达、重复写入的处理方式；Cloudflare 可替换而不改变项目和任务身份。 | 未核实：Anamra 接口、论文只读投影、写入权威及第一条真实跨项目流程未核实；不扩大本次清理为新产品实施。 |
| 4. 涉及既有 ADR 变更时列出冲突和拟议决策，不静默修改旧契约。 | 未核实：Anamra 接口、论文只读投影、写入权威及第一条真实跨项目流程未核实；不扩大本次清理为新产品实施。 |
| 5. 第一版用户范围、任务写入权威与 Anamra 接口核实后再评为 ready-for-agent。 | 未核实：Anamra 接口、论文只读投影、写入权威及第一条真实跨项目流程未核实；不扩大本次清理为新产品实施。 |

## 已删除路径与空间

按删除前 du -sk 的已分配空间统计，共 15472168960 字节（14.41 GiB）；这是删除对象的空间合计，不等同 APFS 快照释放后的磁盘可用空间变化。

| 路径 | KiB |
|---|---:|
| `VibeBuddyMacApp/build` | 3073904 |
| `VibeBuddyApp/build/DerivedData` | 874720 |
| `VibeBuddyApp/build/check` | 1666856 |
| `VibeBuddyApp/build/japanese-device` | 1134652 |
| `VibeBuddyKit/.build` | 278028 |
| `.scratch/deploy` | 5732812 |
| `.scratch/connected-agent-roster/iphone-build` | 1127160 |
| `.scratch/japanese-speech-20261010/VibeBuddyJapaneseQA-before-credentials.app` | 131356 |
| `.scratch/japanese-speech-20261010/VibeBuddyJapaneseQA-before-language-check.app` | 131324 |
| `.scratch/japanese-speech-20261010/VibeBuddyJapaneseQA.app` | 131356 |
| `.scratch/japanese-speech-20261010/VibeBuddyJapaneseQA-before-wording.app` | 131356 |
| `.scratch/connected-agent-roster/e2e/VibeBuddyRosterQA.app` | 132180 |
| `.scratch/japanese-speech-20261010/probe/.build` | 203720 |
| `.scratch/grok-bridge/gui/VibeBuddyGrokQA.app` | 131808 |
| `.scratch/settings-03/credential-regression/.build` | 186640 |
| `.scratch/grok-offline/gui/VibeBuddyOfflineQA.app` | 41668 |

## 本次验证边界

文档引用与 git diff --check 使用 tools/check.py docs 检查；无应用代码变更，不重新构建刚清理的产物，不额外发版。真实设备/收费/商店及未重新复现的观察项均按上表保留未核实，不声称全项目验收已完成。独立评审 exact-head、作者 triage 与合并回执将记录在本次 PR。

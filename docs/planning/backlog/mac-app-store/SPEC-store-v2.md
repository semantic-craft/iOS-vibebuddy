# Mac App Store Spec v2：守望与放行

Status: needs-triage
日期：2026-09-08
基线：main 053a87b
范围：既有产品定义与第一阶段源码评估的综合稿
授权状态：本轮只整理 spec；未确认进入第二阶段，未领取实施票。

## Problem Statement

用户希望从 Mac App Store 安装 VibeBuddy，在离开 Mac 时仍能知道真实代理任务的进展，并从 iPhone 批准操作或回答问题，让任务继续。当前直接分发版依赖外部 CLI、Codex app-server socket、终端自动化和自更新，不能原样作为独立沙盒商店版交付。

用户需要保留完整直接分发版，也不能接受商店版出现没有响应通道的审批按钮、把未授权误报成没有任务，或要求另装 bridge。安装商店版、连接手机及配置 Hook 的过程应由应用引导完成，而不是要求用户运行 Python 安装器。

现有沙盒探针证明了入站 HTTP 与回包的技术前提，尚未证明真实 agent、iPhone 和后续执行组成的审批闭环。方案必须把产品目标与已验证能力分开。

## Solution

新增独立沙盒商店版 VibeBuddy，定位为“守望与放行”。用户启动应用、完成 Pairing、授权代理配置目录并安装 Hook 后，可以观察真实任务，在任务需要决定时收到提醒，并通过已有响应通道批准、拒绝或回答。应用退出或连接失败时，Hook fail-open，代理回到自身交互，不因 VibeBuddy 永久阻塞。

Claude Code 和 Codex CLI 保留 Hook 审批；Codex Desktop 目标是只读观察与等待提醒，使用明确的 read-only card 引导用户回 Mac 处理。该等待提醒必须先证明存在真实可观察信号，不能以超时猜测替代。其它已列入范围的 CLI 保留观察目标。

直接版保持完整能力和原有构建、签名、Sparkle、存储及行为。商店版具有独立容器、默认端口与 Pairing。无法提供的控制入口隐藏，同时在服务端禁止执行；降级能力如实说明。

## User Stories

1. As a Mac 用户, I want 安装一个自包含的商店应用并用 iPhone 扫码 Pairing, so that 我能在局域网内收到真实任务快照，无需另装服务。
2. As a CLI 用户, I want 通过系统对话框授权配置目录并安装、修复或卸载 Hook, so that 我无需运行安装命令，而且已有 Hook 和 Status line 设置不会丢失。
3. As a 用户, I want 授权在重启后恢复，并在撤销或实际失效时看到恢复入口, so that 我能区分“没有任务”和“无法观察”。
4. As a Claude Code 或 Codex CLI 用户, I want 从 iPhone 批准或拒绝真实请求, so that 代理按我的决定继续或停止操作。
5. As a Claude Code 用户, I want 从手机回答代理提出的问题, so that 我不必回到终端才能继续任务。
6. As a 用户, I want Mac 或手机一端回答后另一端撤卡，应用退出时代理回到自身提示, so that 同一请求不会重复执行，也不会永久卡住。
7. As a Codex Desktop 用户, I want 在确有等待信号时收到明确的只读提醒, so that 我知道应回 Mac 处理，而不会点击无效的批准或回答按钮。
8. As a 用户, I want 已有 Session 的名称、上下文与 Claude 用量随 Status line sample 更新, so that 我能了解任务消耗，并把未知或过期数据与真实额度区分开。
9. As a 其它受支持 CLI 的用户, I want 授权后观察任务生命周期，并获得必要的重新信任提示, so that 我知道安装配置与实际接入是否成功。
10. As a 用户, I want Jump 至少把对应宿主应用带到前台，并只看到当前商店版能够执行的操作, so that 界面不会承诺精确定位或 Dispatch 等不可用能力。
11. As a 两版并存的用户, I want Hook 接管后一个请求只到当前拥有者，原设置可恢复, so that 两个版本不会争抢审批或破坏配置。
12. As a 语音功能用户, I want 应用诚实说明 API key 是否可继承，并保留可选语音与用途说明, so that 我能决定是否重新输入，而不会被告知未经验证的共享成功。

## Implementation Decisions

以下先区分已定边界与评估修订建议。第一阶段把修订写入方案和票据，不等于用户已确认实施。

### 已定产品与执行边界

- 新增商店 target，显示名 VibeBuddy，独立 bundle ID；当前拟用标识为 com.vibebuddy.mac.store。商店默认端口 9880，不占 9876 或 9877。保留 Daemon 的 LAN listener 与现有 bearer-token 认证、Pairing、快照及响应契约。
- 直接版构建、签名、Sparkle 与行为不变。共享 Core/Kit 的修改仅限商店所需的显式注入或隔离，默认行为仍服务直接版。
- 商店 bundle 不链接 Sparkle，也不提供自更新菜单。不使用 temporary-exception entitlement、第二安装包或 bridge。Hook 脚本留在 bundle，由外部代理自身执行；商店应用不 spawn 外部 CLI。
- 存储区分应用自有数据与用户授权位置。应用自有数据落入容器，直接版既有路径和大小写保持。ClaudeBackgroundSessions 所读的外部 jobs 属于代理数据，商店不启用 Attach 或后台任务启动。
- 保留 Hook、Status line sample、Live usage feed 的职责：Hook 驱动任务状态；样本只丰富已有 Session，不新建 Session 或推进三态；用量不驱动任务进度。
- 复用 Presence 与 read-only card。没有真实响应通道的等待始终不可远程回答，UI、通知动作、语音和服务端行为一致。直接版的 ADR-0011 app-server 主源与响应能力保持。
- 明确不提供 Dispatch、Attach、终端注入、tmux、精确跳转、Codex Desktop 审批、Codex 实时额度、Cursor cookie 导入和需要 spawn 的用量采集。Claude 用量来自 Live usage feed，缺失或过期按真实状态显示。
- 13 是硬关卡：真实 Claude Code 闭环通过前，14–18 不开工；失败先定因，不自动削减产品范围。

### 第一阶段形成的修订建议，待随实施方案确认

- 11：授权粒度改为 Claude 与 Codex 配置目录。备份、同目录临时文件和原子替换需要目录权限；Codex 授权覆盖配置、sessions 与必要同级资源。bookmark 移动后可能仍可解析，应依据实际访问判断，不能一律报失效。
- 12：默认把审批门放在 PermissionRequest；按当前安装器的最低版本 2.1.257 提示升级，不在商店 spawn CLI 查版本。StatusLineSample 需增加可选版本诊断；无样本或无法识别显示未知，不能声称已兼容。
- 15/16：共享 SPM Core 采用商店运行时隔离，不承诺按 app target 排除包内源文件。商店不启动 app-server 模块、连接或 fallback probe，隐藏相应开关。09 即完成安全启动所需最小隔离，16 再完成完整能力和 UI 验收。
- 安装服务在应用装配处选择直接版 Python 或商店原生实现，保留现有 HookSetup 操作与结果状态；Core 的变换接受明确配置根和安装输入。bookmark 生命周期由应用层管理，长寿命 watcher 持有对应访问权并在停止时释放。
- 原生安装保留事件、matcher、参数、async、timeout、已有审批选择、用户 Hook 和完整 Status line 原对象；写前备份、幂等更新、坏配置不覆盖、失败可恢复。含他人 handler 的混合组不整组删除。
- Claude forwarder 现为 exec-form，不能直接塞 shell 前缀；环境注入方式必须同时经过真实代理执行与接管识别验证。注入 token 文件路径、端口和 support 位置，不将 Claude token 原值写入配置。Qwen native-http 的 query token 是 ADR-0009 既有特例，不能输出到证据。
- 跨版 Status line 接管必须保留原命令备份，不能递归包装或在无法获取旧备份时破坏性覆盖。app 更新路径不变时继续有效，移动 app 后提供修复。
- Jump 复用已有 JumpOutcome.activatedApp，无需新增线协议值。能力禁用覆盖 MenuBarModel 与 VibeBuddyServer 的独立入口，不能仅隐藏手机按钮。
- 17 增加 13 关卡及 14 依赖，以在安装器完成后验证双向接管。不预设改变直接版 entitlement、迁移旧 Keychain 条目或加入签名失败 fallback；共享先用虚构测试值验证。

### 尚未解决的实质事项

- OpenCode 当前安装器复制插件到外部目录，插件也未接入商店 token 文件路径。需要证明可从配置引用并加载 bundle 内插件、传入正确商店配置且可卸载恢复；当前没有选定并验证的实现。
- Codex 的直接版安装器按严格 argv 识别本产品命令。环境前缀可能破坏反向接管；Claude 的识别也有不同约束。命令形状、旧拥有者卸载和跨容器备份恢复仍须实证，不能以 basename 相同推定安全。
- Codex rollout decoder 支持等待事件，不证明 Desktop 实际写入审批等待。必须在隔离真实会话取得证据；缺少信号时本项未完成，禁止以静默、工具执行或超时伪造等待。
- 外部进程读取容器 token 与 Status line 原命令备份尚未测试。失败时回到认证与文件访问定因，不把 secret 写入 Claude 配置作为替代。
- Keychain 既有条目能否在直接版签名不变的条件下读取尚未证实。若必须修改直接版签名或迁移凭据，另行提出具体候选供用户决定；票内允许的重输分支应说明原因，不能伪称继承成功。
- 局域网用途字符串不证明首次提示必然出现；系统实际触发条件与票中提示验收要求需要真实证据。不能默默取消该验收项。

## Testing Decisions

1. 首选最高层测试边界：隔离商店应用的实际装配，经真实代理 Hook 进入 Daemon，再由真实 iPhone 响应并核对代理后续行为。成功标准是用户可见结果与真实执行一致，不是按钮出现、HTTP 非 401 或 fixture 被 decoder 接受。
2. 模块间尽量复用已有注入点：VibeBuddyServer 的 monitor、规则、响应与跳转回调，现有存储 URL 参数，以及 KeychainStore.Operations。新增边界集中在商店运行装配与原生安装服务，避免为每个类新增独立抽象。
3. 原生安装器使用现有安装器样例作语义对照，覆盖安装、重复安装、审批保留、混合组保护、卸载、原 Status line 恢复及写入失败。Python 对照运行必须受控覆盖所有配置与备份位置；只设置 CLAUDE_CONFIG_DIR 不能隔离硬编码 home 的 Python 安装器。exec-form 与 shell-string 的传输差异允许不同，但事件行为不能少。
4. 09 验证实际签名中的 app-sandbox、容器 home、9880 监听、无 Sparkle、用途描述及 iPhone Pairing/快照；直接版在隔离构建中验证原构建与签名设置，不替换日常应用。
5. 10/11 验证 token 为 0600、重启值不变、Pairing 不丢失、各数据根互不覆盖，以及授权、跳过、重启、移动后有效解析、撤销、实际失效与恢复。日志仅报告结论，不列用户目录内容。
6. 13 真实验证批准、拒绝、AskUserQuestion 回答、Mac 先答后手机撤卡、退出 fail-open、样本仅更新已有 Session。使用隔离目录中的可核验无害动作；分别观察连接拒绝与有限等待，不将所有故障承诺为一秒内返回。Presence 的本地处理与 away 远程放行分开验收。
7. 14/15 验证 Codex CLI 真实审批、至少另一个 CLI 的真实生命周期，以及 Desktop 真实等待信号和 read-only card。安装成功、合成事件、实际宿主执行三者分别记录；无法获取 Desktop 信号时保持未完成。
8. 16/17 验证 UI、语音及服务端都不执行禁用能力；Claude 样本缺失/过期如实显示；两版隔离运行时一个 Hook 请求只被当前拥有者接收，双向安装和旧版卸载不破坏当前配置。Keychain 使用虚构条目，仅记录 OSStatus 与相等结论。
9. 沿用现有 Server/Reducer/StatusLineSample/安装器测试，只增加关键纯逻辑或已复现回归所需少量测试。实施时运行 VibeBuddyMac 与 VibeBuddyKit 两个包的 swift test；涉及 iOS 构建时不传 -sdk。测试通过不替代实际应用和真机验收。
10. 18 分别记录本地 Apple Development 沙盒验证与正式分发 Archive 的签名检查，核对实际 bundle、隐私、截图和干净账户 reviewer 复现。构建、签名、归档、上传、提交与审核是不同状态。

## Out of Scope

- 本次 spec 整理不包含应用实现、领取票、替换运行实例、提交、推送、跨机同步、发布或 App Store Connect 写入。
- 不改变直接版构建、签名、更新、存储、行为；不自动迁移或读取用户真实 API key，不修改真实代理配置。
- 不新增 bridge、第二个安装包、外置代码复制、自更新或临时例外 entitlement。
- 不实现商店版已明确排除的 Dispatch、Attach、精确终端控制、Codex Desktop 应答及实时额度等能力。
- 不通过删除 OpenCode、Desktop 提醒或其它既定产品目标来消除实施困难；这些属于未完成要求，修改范围需用户决定。
- 不扩展全量测试矩阵、无关架构重构或新的项目管理系统；不执行已作废的 02–08。

## Further Notes

本稿按 to-spec 模板综合已有讨论，不重新访谈。Status 为 needs-triage，因为上述实质问题及实施确认尚未关闭；不是 ready-for-agent，也不是第二阶段授权。

现有工作票 09–18 仍是逐票实施与证据的权威，本稿承接产品定义和评估修订。历史 [Spec v1](SPEC-store-v1.md) 保留裁决修正背景；[实施方案](IMPLEMENTATION-PLAN.html) 承载具体步骤与文件定位；[评估记录](evidence/PLAN-REVIEW.md) 区分静态检查与未测事项；[CHECKLIST](CHECKLIST.md) 维护状态与下一次入口。

修订依赖顺序：09 → 10/11 → 12 → 13；13 通过后推进 14、15、16；17 依赖 09、12、13、14；18 依赖 14–17。每票领取写 Owner，全部验收有证据后才写 Progress: completed。13 失败先定因。

实施验证使用 CLAUDE_CONFIG_DIR、CODEX_HOME 或 Settings 授权的本次隔离目录；不替换 /Applications/VibeBuddyMacApp.app，不修改真实 ~/.claude 与 ~/.codex，不占 9876/9877。商店本地签名用 Apple Development 与 tools/vibebuddy-store.entitlements，必须从 codesign 实际输出核对 app-sandbox。日志、票和截图不包含 token、key、真实目录内容或未遮盖的 Pairing QR。

已有探针仅支持沙盒外 HTTP 入站回包前提；A1 外部读取容器文件、bookmark GUI 恢复、Keychain 共享、真实完整审批链路和审核结果均未证明。A1–A4 已更正现存报告，独立原裁决报告未定位，不声称修改该原件。

本稿只保存于本地 tracker；该目录被 Git 忽略，不代表已提交或跨机保存。

# Grok Bot 完成通知与离线补收研究

日期：2026-10-11。对象：桌面 Grok Bot（`com.anysphere.sand`），不是 Grok Build 或 Cursor Cloud Agents。
状态：公开来源、当前源码与图灵现场对照实验已核对；本文件中的离线补收设计尚未实现或验收。已安装的通知桥、日语播放和额度验收不因此改变。
代码基线：`7824340b4dd340e1ac121889ac47428f27101c71`。

## 结论

可以先把现有通知桥升级为“启用后、保留窗口内、已同步到 Mac 的文字通知自动补收”。这不要求每次提醒 Bot，也不需要模型定时阅读所有会话。它仍然不能保证所有任务终态：没有发送文字、尚未同步到本机或已经从缓存裁剪掉的结果，没有可补收的来源。

本次查到了官方 **Enterprise OpenTelemetry** 的 Grok Bot 动作事件，但没有找到足以证明个人账户可订阅“所有任务完成”的公开契约。官方 routine webhook 是启动任务的入口；第三方回调协议及 Tailscale 邮箱解决传输，不会自动产生缺失的终态事件。这个结论限定于下列实际阅读的文档和源码，不能扩写成“平台不存在此功能”。

## 公开来源能证明什么

| 来源 | 已核对的能力 | 不能据此声称的能力 |
| --- | --- | --- |
| [官方 Routines](https://cursor.com/help/grok-bot/routines) | 云端运行；webhook 的 200 只表示接收并启动；手机有近期 Running / Succeeded / Failed 历史；每次 routine 运行使用额度 | webhook 是向 Mac 推送终态；近期历史有公开增量 API；定时让模型查聊天可以无成本覆盖所有任务 |
| [官方 OpenTelemetry Export](https://prod.cursor.com/docs/enterprise/opentelemetry-export) | Enterprise 团队配置服务端导出；需要公网 HTTPS 接收端；日志至少一次投递并以 `cursor.event.id` 去重；目标创建前没有历史补发，删除或禁用会丢在途数据 | 普通个人账户可直接启用；Mac 长期离线的无限重试或历史恢复保证 |
| [官方 Wire Reference](https://prod.cursor.com/docs/enterprise/opentelemetry-export/wire) | `grok_bot_agent_actions` 需要 Action Recording；有消息投递、routine 结算及可选 turn 关联字段；routine `success` 包含暂停等用户，个人账户被跳过；文档还列出审批恢复等覆盖缺口 | routine success 等于用户目标完成；任意任务均有完整终态；工具调用成功等于任务成功 |
| [grokbot-sdk README](https://github.com/adam91holt/grokbot-sdk/blob/c14347fa82d167b9a5984ec1baff56b2f074485a/sdk/README.md) | 第三方 SDK 暴露主机 `/events`、transcript 与 roster；明确不存在主机 `waitForCompletion`，等待由 SDK 推断 idle | 当前账户允许访问此内部主机接口；SDK 测试即当前客户端兼容证明 |
| [SDK client.ts](https://github.com/adam91holt/grokbot-sdk/blob/c14347fa82d167b9a5984ec1baff56b2f074485a/sdk/src/gateway/client.ts#L236) | `events()` 是认证 SSE 的 channel/payload 迭代；本函数没有持久游标或 Last-Event-ID 恢复参数；`waitForIdle` 汇合 roster、异步任务、subagent 等信号 | 断线可恢复的任务事件日志；idle 严格等于一个任务完成 |
| [grokbot-mcp-bridge SPEC](https://github.com/kinopeee/grokbot-mcp-bridge/blob/main/SPEC.md) | 它自己生成 run/request ID，把 callback URL 送入任务，等待 Bot 回调并保存状态 | 平台会对桥外的已有、新建、群组及静默任务自动回调 |
| [yobiru README](https://github.com/chekusu/yobiru/blob/ab4350b16549fdf4ce2fcf068f4d67124a5b6b77/README.md) | Tailscale 消息、收件箱、ACK、唤醒适配；可把账户支持的 Grok routine webhook 当唤醒入口；项目明确实际 Grok 唤醒周期仍需账户验收 | 内置 Grok 全账户完成观察器；装插件等于接收器和唤醒已部署 |

Enterprise 文档是后续正式数据源的候选，不能直接改装个人账户链路。消息正文还需要相应内容导出的单独 opt-in；动作元数据本身不能生成忠实的结果摘要。[官方说明](https://prod.cursor.com/docs/enterprise/opentelemetry-export#conversation-content)

## 当前代码为何会漏离线通知

依据 [ADR-0034](adr/0034-grok-bot-delivered-results.md)、[GrokBotCacheMonitor](../VibeBuddyMac/Sources/VibeBuddyMacCore/GrokBotCacheMonitor.swift) 与 [GrokBotResultInbox](../VibeBuddyMac/Sources/VibeBuddyMacCore/GrokBotResultInbox.swift)：

- 每次启动或切换账户把 `baseline` 设为当前时间；此前发出的消息即使刚同步到本机也会跳过。`seen` 只在内存，超过 20,000 项也会重置时间边界。
- 内容范围限于已知 Bot 的 `send-message` 文字，没有 `deliverTo`；主动排除用户输入、附件及其他消息类型。缓存文件有 8 MiB 上限，解析失败跳过。
- Inbox 按 Bot / conversation / turn 身份落盘去重，保留七天、最多 4096 件；容量满时反压。有效载荷也拒绝七天以前的源时间。
- 先落去重文件再投影卡片；崩溃在两者之间会漏一张卡。重复回执不会重新投影，重启也不恢复旧通知卡。这是现有防重复播报取舍，不能当作可靠离线队列。

## 建议的最小补收设计

以下是工程设计推断，不是已提供的平台保证。保留现有消息识别和账户隔离，只扩展本地可靠性。

1. **持久化每账户的启用边界。** 首次启用记录一次 `enabledAt`，不播此前历史；后续重启加载同一边界。账户切换隔离显示，但不要删除该账户的补收状态；重新选中时继续其窗口。迁移首版时以迁移时刻开始，不把旧消息当新通知。
2. **窗口重扫加稳定 ID。** 每次扫描当前可读缓存，在 `max(enabledAt, now - retention)` 之后找未接收 ID。不要仅使用“最后消息时间”或文件 mtime 作永久游标：同步可能乱序、同毫秒多消息，旧源时间也可能晚到。mtime 只能优化读取。定期完整复核解决同尺寸/同 mtime 或旋转缓存；缓存没有的数据仍然不可恢复。
3. **接收与待展示状态一起持久化。** 以账户、会话、消息 ID 为唯一身份，正文及 sender 一起保存。接收成功必须意味着 durable pending 已建立；投影失败或崩溃后恢复 pending。明确区分 pending / delivered / read，不能用“已存在收据”同时代表已展示和已读。恢复同一 ID 的卡片应幂等，已读卡不复活。
4. **播报与入箱分开。** 离线积压先可靠入箱；默认用一次日语提示“离线期间收到 N 条通知”，再提供逐条重播，避免几十条自动连续朗读。原始通知和源时间保留，显示补收标识；时间排序不改写任务发生时间。批量摘要是否进一步使用模型应是可配置体验。
5. **容量和过期可见。** 先沿用七天边界及 4096 容量，遇到满、损坏、已过期或 schema 不认识时展示明确状态，不把健康的目录扫描称为完整覆盖。容量失败不得推进已处理状态；成功 ACK 后才提交对应 ID。超过窗口只提示“无法确认完整”，不能宣称零遗漏。
6. **若将来接正式云端事件源**，复用 durable pending 和 ID 规则；游标只在本地事务落盘成功后推进。通过原生推送/受支持 API 补历史，云端 outbox 保留至 Mac ACK。yobiru 可承担其中传输，但其 ACK 必须对应持久接收，而不是模型读过提示词。

不要求声音恰好一次：音频播放与数据库无法原子提交。应明确采用防重复或防漏的恢复策略，并验收崩溃窗口；通知卡的可靠入箱不应依赖音频成功。

## 声称“所有任务自动覆盖”前缺少的证据

需要当前账户实际支持的服务端契约，至少具备：自动枚举现有与新增 Bot/群组、稳定 task/turn ID、任务终态及其语义、增量游标、断线重放期限、完整性/截断信号。必须区分完成、失败、取消、等待用户、被新消息替代、转交和子任务；一条发送给用户的文字不是终态证明。

验收矩阵必须包含：普通会话、未打开会话、新 Bot、群组、routine、委派、静默结束、失败、取消、审批等待及恢复，以及 Mac 离线/客户端退出/桥重启/账户切换后重连。同源事件重复到达、乱序、缓存截断和保留期耗尽需给出实际结果。只有被该协议自动覆盖的类别才能列入覆盖声明。

逐 Bot 植入“完成时发回执”的提示词依然依赖模型遵循；定时唤醒模型读所有会话既消耗额度，也没有严格完整性。两者可以作为明确标注的辅助通知，不应更名为全自动任务终态接入。

## 图灵现场核对与本机证据

2026-10-11，与用户的图灵 Bot 直接协作；未修改 Bot 人设、例程、账号权限或部署。图灵报告当前工具没有账户级任务列表、终态订阅或不占模型调用的后台读取入口。它把发用户消息工具标为 `SendToUser`，`end_turn` 为布尔入参。此工具目录描述是 Bot 当场自述，不是平台完整性保证；以下缓存结果由 Mac 独立核验。

只在图灵自己的对话中要求两条对照消息：

| 实验 | 消息 ID | seq | 实际落到 Mac 的字段 |
| --- | --- | --- | --- |
| 进度通知，请求 `end_turn=false` | `t365s1523` | 1523 | `id, kind, message, requestId, seq, timestampMs` |
| 结束通知，请求 `end_turn=true` | `t365s1524` | 1524 | 完全相同 |

两条的 `kind` 均为 `send-message`，`message` 仅有 `type, content`。缓存没有 `end_turn` 或对应终态字段。它们相隔约 7 秒，因此“收到消息即完成”会把进度通知误判；文本分类也无法覆盖静默结束。这里只证明该版本、该对话样本不保留差别，不推出所有可能的事件源都不存在。

同一个实际副本在取样时有 200 条记录（82 条用户 message、111 条 send-message、7 条 event），存在 `epochHint`、`acceptedSequenceHint`、`precedingTimestampMs`、`persistedAt`。event 的字段属于 automation 管理动作，不能当全任务终态。此前安装验收消息 `t363s1519` 仍可按 ID 从缓存读取。200 是本次观察到的数量，不是经完整验证的全局保留上限；`acceptedSequenceHint` 也不能未经验证就用作消息提交游标。

这支持有界历史重扫的可行性，但不是 Mac 断网/客户端关闭后的端到端补收验收。需要分别验证：桥退出而官方客户端仍运行、Mac 整体离线、客户端退出、缓存换 epoch、消息超出缓存窗口，以及未打开会话的同步覆盖。首次启用只建立边界；七天只是本地保留策略，不能保证上游缓存也保留七天。

本地脱敏证据：`.scratch/grok-bridge/completion-research/cache-metadata.json`、`progress-final-comparison.json`。不保存或公开其他 Bot 的私人正文，不记录凭据。

图灵对上述补收设计的第二次复核指出：补收只能重建已经发送的话，无法凭缓存恢复失败、取消或静默结束的真实任务状态。该提醒与本机对照实验一致；没有据此修改部署或安排定时模型扫描。

## 建议实施顺序

先实现并验收有界通知补收与可靠入箱；其声明仅覆盖实际上游可恢复的文字通知。随后再扩展未打开会话、新 Bot、群组及附件的可观测范围，逐项记录支持与缺口。真正全任务终态需要补齐官方账户级事件契约，在此之前保持“Bot 通知”命名，不将进度消息自动标为任务成功。不建议为此单独升级企业订阅，因为已公开事件仍存在终态语义与覆盖缺口。

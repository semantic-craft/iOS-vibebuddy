# 手机与 Apple Watch 的官方依据

核验：2026-09-05。Apple 正文已打开；JavaScript 页使用同站 DocC JSON 原文核验。以下是平台依据，**不代表 #42 已实现或已获真机验收**。

| 能力 | 官方依据与可承诺边界 |
|---|---|
| 口述 | [系统文本输入 API](https://developer.apple.com/documentation/watchkit/wkinterfacecontroller/presenttextinputcontroller(withsuggestions:allowedinputmode:completion:)) 自 watchOS 2 支持听写并返回用户接受的文字。采用口述→核对文字→发送，取消不发送；这不是持续实时通话。 |
| 朗读 | [AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer) 自 watchOS 2 可用，支持朗读、暂停、停止及输出路由。按需读出 agent 实际答复；语言、扬声器／耳机效果须真机验证，不默认自动外放。 |
| 通信 | [WCSession](https://developer.apple.com/documentation/watchconnectivity/wcsession) 连接配对 iPhone，不是直连 Mac；即时消息要求 reachable，后台传输可能延后。[官方示例](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity) 要求实体设备验证。队列接收不等于 agent 已受理。 |
| 独立能力 | [内容更新指南](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date) 推荐 URLSession，通过 iPhone、Wi-Fi 或蜂窝通信，后台调度有约束。[TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos) 将 WebSocket 列入受限底层网络。先采用 HTTP 和异步结果；实时通话另行研究。 |
| 通知路由 | [转发规则](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding)：可转发通知在 iPhone 解锁亮屏时去手机，否则通常去佩戴且解锁的 Watch。[接入指南](https://developer.apple.com/documentation/watchos-apps/enabling-and-receiving-notifications) 支持 Watch APNs token，但 companion 双端投递由系统择优。单独 Watch 路由及去重要真机验证；不能承诺腕上必达。 |
| 紧迫度 | [Time Sensitive](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive) 可被用户关闭；[HIG](https://developer.apple.com/design/human-interface-guidelines/managing-notifications) 要求事件当前且需即时关注。[Critical](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/critical) 另需 entitlement。“重要”不自动升级所有完成消息，不用 Critical 绕过 Focus。 |

产品推论：采用“口述文字＋任务协议＋异步答复＋按需朗读”。任务身份、去重、过期回应拒绝与已处理同步由产品实现；最近输出标注来源、时间、截断状态。重要事件不被 Mac 在场规则丢弃，但仍尊重系统通知设置。“无弊端”无法保证；应控制误识别、重复任务、过期信息和打扰，明确网络与系统调度限制。

## Agent 官方依据（主 agent 已打开核验）

- [Codex App Server](https://learn.chatgpt.com/docs/app-server)：`thread/start` 新会话，`turn/start` 新轮，`turn/steer` 修改运行中轮次且需 `expectedTurnId`；失败不可静默改为 start。stable 与 experimental 能力分开判断。
- [Claude CLI](https://code.claude.com/docs/en/cli-reference)：有 `--bg` 等官方启动能力；仍需核验使用版本与项目目标。
- [Claude hooks](https://code.claude.com/docs/en/hooks)：`PermissionRequest`、`updatedPermissions` 支持原生审批与权限更新。优先用原生规则减量；在场感知不取代权限，也不是新增守护进程自动放行白名单的理由。

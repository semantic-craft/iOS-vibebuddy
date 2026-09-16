# VibeBuddy 1.3.22 — macOS

- Agent CLIs 设置改为后台检测并合并重复刷新，减少打开设置时的卡顿；移除 Qwen、Kimi CLI 的现行接入，保留历史记录身份和用户配置。
- 历史索引按目录变化增量更新；索引繁忙时仍可搜索，已打开的对话可显示新消息。
- 修复 Codex 分叉历史的父子身份混淆，保留各自正文、搜索结果和用户标记。
- Cursor 托管任务支持重启后继续同一会话、完整计划与工具结果阅读，以及 Mac 内停止任务；修复正文持续加载和继续对话的 CLI 检测问题。
- 修复任务结束与取消同时发生时，迟到的问答或审批清理把已完成任务改回工作中、丢失完成记录的问题。
- 完成摘要按原生任务轮次精确恢复，重启后保留正文；首次发现、迟到事件和冲突不会串入其他轮次。摘要不可用时记录有限诊断原因。

- 摘要和朗读不再默认显示“未验证”。连接测试、生成样例与试听入口更清晰，忙碌时说明暂不可用的原因，试听与朗读设置集中显示。
- 模型帮助链接按实时对话、文本生成和语音合成分别提供对应文档。
- 通知设置显示 macOS 权限状态，可打开系统通知设置，返回后刷新。等待授权选择时的提示更准确。
- 统一配额提醒的静音规则说明，并根据 Cursor 登录来源显示适用的帮助。
- 费用明确标为按 token 标价估算，不代表实际账单，并补齐中文说明。
- 同名项目显示可区分的父路径，保持完整路径身份、任务计数和选择行为。批量生成项目标签，减少重复计算。

## English

- Detect Agent CLIs off the main thread and coalesce refresh requests to reduce settings stalls. Retire active Qwen and Kimi CLI integrations while preserving historical identities and user configuration.
- Update history indexes from directory changes, keep search available during indexing, and show new messages in an open conversation.
- Preserve distinct Codex parent and fork identities, conversation bodies, search results and user metadata.
- Resume managed Cursor sessions after a restart, read full plans and tool results, and stop tasks from the Mac. Fix stuck body loading and CLI detection when continuing a conversation.
- Preserve completed turns when delayed question or approval cleanup races with task completion or cancellation.
- Recover completion bodies using exact native turn evidence and retain them across restarts. Handle first discovery, late events and conflicting evidence without borrowing another turn. Record finite failure diagnostics for unavailable summaries.

- Remove default unverified labels for summaries and read-aloud. Clarify connection tests, sample generation, voice previews and busy-state feedback, with previews next to reading settings.
- Link to model documentation for the selected purpose: realtime conversation, text generation or speech synthesis.
- Show macOS notification permission, open System Settings and refresh on return. Describe a pending permission decision accurately.
- Align quota guidance with existing quiet-mode behavior and show help for the selected Cursor login source.
- Label token costs as list-price estimates rather than actual charges, with updated Simplified Chinese text.
- Distinguish same-named projects with parent paths while preserving identities, counts and selection. Generate project labels in batches to reduce repeated work.

Mac build 36. This release updates the Mac companion; it does not publish an iPhone or Watch update.

## Validation notes

See [integrated acceptance](qa/release-1.3.22.md) for the earlier build 35 evidence and [build 36 release verification](qa/release-1.3.22-build36.md) for the final release candidate. Earlier installed-build evidence does not establish installation acceptance for build 36.

Cursor may return an upstream error as ordinary assistant text with a normal end-of-turn signal. The text remains visible, but VibeBuddy cannot reliably classify that response as a structured failure. Continuing the session and stopping a task have been exercised; this does not establish that the failed turn completed its requested work. Automatic read acknowledgment, physical iPhone/Watch acceptance and live IDE Hooks acceptance are not claimed for this release.

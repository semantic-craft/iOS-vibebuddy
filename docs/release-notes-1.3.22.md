# VibeBuddy 1.3.22 — macOS

- 完成摘要按原生任务轮次精确恢复，重启后保留正文；首次发现、迟到事件和冲突不会串入其他轮次。摘要不可用时记录有限诊断原因。

- 摘要和朗读不再默认显示“未验证”。连接测试、生成样例与试听入口更清晰，忙碌时说明暂不可用的原因，试听与朗读设置集中显示。
- 模型帮助链接按实时对话、文本生成和语音合成分别提供对应文档。
- 通知设置显示 macOS 权限状态，可打开系统通知设置，返回后刷新。等待授权选择时的提示更准确。
- 统一配额提醒的静音规则说明，并根据 Cursor 登录来源显示适用的帮助。
- 费用明确标为按 token 标价估算，不代表实际账单，并补齐中文说明。
- 同名项目显示可区分的父路径，保持完整路径身份、任务计数和选择行为。批量生成项目标签，减少重复计算。

## English

- Recover completion bodies using exact native turn evidence and retain them across restarts. Handle first discovery, late events and conflicting evidence without borrowing another turn. Record finite failure diagnostics for unavailable summaries.

- Remove default unverified labels for summaries and read-aloud. Clarify connection tests, sample generation, voice previews and busy-state feedback, with previews next to reading settings.
- Link to model documentation for the selected purpose: realtime conversation, text generation or speech synthesis.
- Show macOS notification permission, open System Settings and refresh on return. Describe a pending permission decision accurately.
- Align quota guidance with existing quiet-mode behavior and show help for the selected Cursor login source.
- Label token costs as list-price estimates rather than actual charges, with updated Simplified Chinese text.
- Distinguish same-named projects with parent paths while preserving identities, counts and selection. Generate project labels in batches to reduce repeated work.

Mac build 35 (integrated settings and completion recovery).

## Validation notes

See [integrated acceptance](qa/release-1.3.22.md). The installed build passed real Desktop completion/body and normal saved-key summary generation checks; native summary sample and voice preview playback also completed automatically. Existing macOS notification permission is Denied, so banner delivery was not accepted. Human hearing, phone/Watch and live microphone conversation are not claimed.

# vibebuddy 1.3.14

## 中文

- Mac 任务看板、菜单面板、Glance 和设置统一为简洁的 Cursor 风格，保留绿色重点色、清晰的状态文字和始终可打开的 New task。
- 自主任务以目标、进度和本轮结果为中心。只有确认终止的失败进入「需要你」；执行中出现过工具错误，不会被当作最终失败。
- 支持本轮结果已读／标回未读、下一个待处理任务，以及需要介入与未读结果的合并计数。跳转到 agent、听完播报和标回未读不会重新触发已读或提醒。
- 完成播报按任务排队，可暂停、跳过、重播，实时语音优先；结果和检查明确标注来源，不把 agent 自述当作独立验收。豆包、Qwen、Gemini 支持标准、邻家小妹和火辣少女风格。
- 详情提供有界工具活动记录，以及明确选择未提交、已暂存或分支范围的只读 Git diff。工作区改动不归功于某个单独任务。
- 历史摘要提供行动简报、会话复盘和归档记录；加强历史时点、材料覆盖和操作授权边界。DeepSeek 可用于文字摘要，朗读需另选语音服务商。
- Mac App 内置 `vibebuddy-mcp`，通过 CLI 和 stdio MCP 查询会话、项目、全文、已存摘要及当前任务状态。Connect 页面提供客户端配置。查询不改写索引，刷新由 App 或显式 `index` 操作完成。
- 历史来源支持 Claude Code、Codex 和 Cursor 本地 transcript；Grok Build 首版只提供会话列表／标题。项目内历史与交接技能保留准确来源会话身份。

## English

- A unified Mac dashboard, menu panel, Glance and Settings, with green accents and an accessible New task entry.
- A task desk centred on goals, progress, exact-round results and unread navigation. Recoverable tool errors remain Working; confirmed terminal failures need attention.
- Bounded, sequential task announcements with pause, skip and replay; listening never acknowledges a result. Read-aloud styles are available for Doubao, Qwen and Gemini.
- Attributed tool activity and read-only workspace diffs with explicit uncommitted, staged and branch scopes.
- Historical briefing, review and archive summaries preserve coverage, historical context and authorization boundaries; DeepSeek is available for text summaries.
- A bundled `vibebuddy-mcp` CLI/stdio server exposes six read-only history and status tools, with client setup in Connect and source-identified project handoff skills.

## 使用条件与已知限制 / Requirements and limits

- 本次分发资产为签名、公证的 macOS App。仓库同步包含 iPhone／Watch 界面和共享状态更新；不代表已向实体设备安装或提交 App Store。
- Codex／Cursor 的用户级 MCP 配置与重启连接验收仍需在对应客户端完成；Claude 项目级 MCP 和同机接力已有实际验收。
- Grok Build 不提供全文、全文搜索或摘要生成；Cursor 加密 IDE 历史及云端历史不在此接口范围。
- 真实腕上通知／触觉、部分 provider 特殊等待、系统通知与实时语音联合场景，以及不同风格的人工听感仍待验收。Watch 在通知先于最新 relay 到达时，可能显示结果却未确认对应轮次已读；已保留后续修复记录。
- 历史摘要是基于所提供材料的模型输出，仍可能冗长或包含泛化建议；已保存摘要不会因风格偏好改变而重写。
- This release distributes the macOS app. Physical-device acceptance, Codex/Cursor client connection checks, and human listening are tracked separately; Grok history is metadata-only.

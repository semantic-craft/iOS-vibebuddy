# 03: 语音动作不要落到用户没点名的另一个等待中的任务

**What to build:** 语音模型发出 `approve_session` / `deny_session` / `answer_session` 时，App 目前只检查点名的项目能否唯一匹配、是否还有可回答的请求（`VoiceSessionMatch` 加 `performVoiceAction` 的复核）。如果模型点名的是另一个仍在等待的任务，这个动作会被执行。需要一道与模型无关的确认：比如动作的目标必须出现在这一轮用户话语的转写里，或者目标和用户说的不一致时先念出目标、等用户确认。

**Blocked by:** None

**Status:** needs-triage（先定方案：转写比对，还是二次确认）

**依据（2026-09-24 路线图验收，D-U 合成语音，Qwen `qwen-audio-3.0-realtime-plus`，中文）：**
- 第 1 轮用户说「拒绝 grape 项目里等待的请求」，识别成「拒绝高客项目里存在的请求」，模型发了 `deny_session(orange)`。
- 这次被拒，只是因为 orange 的卡片刚因 25 s hold 超时消失。如果 orange 还挂着（比如 Cursor / Grok 的 ACP 审批没有这个超时），拒绝就会落到 orange 上。
- 第 4 轮的输入转写是「批准调整的请求」「拒绝你这个请求」，模型给出的项目名却是正确的 桃子、李子。转写和模型实际听到的是否同一路输入，代码没有说明，所以分不清模型是听对了，还是按唯一候选猜的。
- 证据：`~/Projects/_shared-work/iOS-vibebuddy/roadmap-agent-acceptance-2026-09-24/du/qwen-zh-1.jsonl`、`qwen-zh-4.jsonl`；汇总见 `docs/planning/backlog/roadmap-audit-2026-09-24.md` 末节。

- [ ] 定方案，并写进 ADR-0001 或语音相关 ADR。
- [ ] 回归测试：模型对 B 发动作，而用户话语只提到 A，这个动作不能发出（或者先要求确认）。
- [ ] 用同一套合成语音验收（`kit/duharness-main.swift`）重跑 Gemini、Qwen：批准、拒绝、回答仍然都能落到正确的目标。

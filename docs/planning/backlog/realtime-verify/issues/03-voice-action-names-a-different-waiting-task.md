# 03: 语音动作不要落到用户没点名的另一个等待中的任务

**What to build:** 语音模型发出 `approve_session` / `deny_session` / `answer_session` 时，App 目前只检查点名的项目能否唯一匹配、是否还有可回答的请求（`VoiceSessionMatch` 加 `performVoiceAction` 的复核）。如果模型点名的是另一个仍在等待的任务，这个动作会被执行。需要一道与模型无关的确认：比如动作的目标必须出现在这一轮用户话语的转写里，或者目标和用户说的不一致时先念出目标、等用户确认。

**Blocked by:** None

**Status:** 已实现，待合并（分支 `claude/rv03-voice-target-guard`）

**依据（2026-09-24 路线图验收，D-U 合成语音，Qwen `qwen-audio-3.0-realtime-plus`，中文）：**
- 第 1 轮用户说「拒绝 grape 项目里等待的请求」，识别成「拒绝高客项目里存在的请求」，模型发了 `deny_session(orange)`。
- 这次被拒，只是因为 orange 的卡片刚因 25 s hold 超时消失。如果 orange 还挂着（比如 Cursor / Grok 的 ACP 审批没有这个超时），拒绝就会落到 orange 上。
- 第 4 轮的输入转写是「批准调整的请求」「拒绝你这个请求」，模型给出的项目名却是正确的 桃子、李子。转写和模型实际听到的是否同一路输入，代码没有说明，所以分不清模型是听对了，还是按唯一候选猜的。
- 证据：`~/Projects/_shared-work/iOS-vibebuddy/roadmap-agent-acceptance-2026-09-24/du/qwen-zh-1.jsonl`、`qwen-zh-4.jsonl`；汇总见 `docs/planning/backlog/roadmap-audit-2026-09-24.md` 末节。

## 决定（2026-09-24，agent 自行定案）

选**转写比对**，比不上时**扣住不发、要用户说出名字确认**。写进 ADR-0008「Named target」一节。

- 批准、拒绝、回答、指示这四种会改动任务的动作，只有当用户这一轮说的话里出现了目标的项目名或会话标题，才会发出（`VoiceTargetCheck`）。「这一轮」= 伙伴上次出声之后用户的所有转写和字幕；伙伴一开口就重新计，早先提过的名字不算数。
- 比对只放宽写法：不分大小写、忽略空格和标点（"vibe buddy" 算 `vibe-buddy`）；英文名要整词（"approve" 里的 app 不算）；项目名里独有的一个词也算；名字只出现在另一个更长的任务名里不算（"app-server" 不点名 `app`）。
- Qwen 的转写比工具调用晚 0.1–0.7 s，所以先最多等 2.5 s 再判。
- 比不上就不发。工具结果告诉模型听到的是哪个名字（或没听到名字），让它请用户说出目标的名字；iPhone 语音条和 Mac 语音面板显示一行「没有发给 X」。确认的办法是用户把名字说出来，同样过比对；光说「对」「好」不放行。
- 标记已读不改任务，不受这道检查。

没选的：每次都口头问「确定吗」（慢，而且把「不」听成「对」就放行了）；只在多个任务同时等待时才检查（用户点名的任务不在等待时，唯一在等的那个照样会被执行）。代价：如果语音识别每次都把名字听错（比如中文里夹英文项目名），这个任务就没法用语音操作，只能点卡片。

- [x] 定方案，并写进 ADR-0008（Named target）。
- [x] 回归测试：模型对 B 发动作，而用户话语只提到 A，这个动作不能发出（或者先要求确认）。`VoiceTargetCheckTests` 复现了 grape→orange：转写晚到、点名 grape 时 `deny_session(orange)` 被扣住，改发 grape 才发出；乱码转写被扣住，光说「对」不放行，说出 orange 才放行。
- [x] 合成语音重跑 Gemini、Qwen：批准、拒绝、回答仍然都能落到正确的目标。用的是精简版 harness（真实供应商 + `VoiceCallCoordinator` + 记录型 handler，三个任务整轮都在等待，错的目标一直是活的），没起 hub。结果：10 次动作全部发出、落对，0 次误扣：直接点名 7 次（Qwen 中文 3、Gemini 英文 3、Qwen 中文里夹英文名 1），先不点名、再说出名字 3 次（Qwen 中文、Gemini 中英文各 1）；Qwen 转写比工具调用晚 0.04–0.19 s，被等待窗口接住。「不点名」那一轮两家模型都先反问、没有乱发。扣住这条路没被真实模型触发（这次 TTS 把 grape 念成 grip，模型给的名字在范围外，被原有的范围检查拒了），由单元测试用 9-24 的原始转写覆盖。证据：`~/Projects/_shared-work/iOS-vibebuddy/rv03-2026-09-24/`（harness 源码和 6 份 jsonl）。

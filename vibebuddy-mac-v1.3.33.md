# VibeBuddy 1.3.33 — macOS

**升级后请做一次**：打开 设置 › 代理 CLI › 维护，点「安装／修复」。这一步会把 hook 迁到固定目录，让 Claude 的等待改为 60 秒，并为 Grok 接上状态栏。如果你用 Codex，之后在 Codex 的 `/hooks` 里再信任一次，以后更新 App 就不用再信任了。

- 更省电：删掉了 History 会话存档（它的全文索引会反复重建），新版首次启动时会删除旧索引，腾出磁盘空间。1.3.32 在一个会话运行时平均约 11% CPU；1.3.33 空闲约 1.5%，5–6 个会话同时运行约 6%。启动时的 CPU 突发和菜单栏长时间运行的内存增长也修好了。实时会话阅读保留；`vibebuddy-mcp` 里依赖存档的 sessions / projects / search / summary / index 工具随之移除。
- hook 安装改由 App 自己完成，不再需要 python3；hook 调用 Mac 时，令牌不再出现在进程参数里。
- 手表来得及回答了：Mac 前没人时，Claude 的审批和提问最多等 60 秒（原来 25 秒），需要先做上面的「安装／修复」。
- Claude：带后台任务的回合不再被误报为完成，`/loop` 的轮次不再反复提醒；后台会话改读官方 `claude agents --json`；1M 上下文的会话不再被显示成 200k。
- Grok：显示上下文与花费（新会话生效，需要先做「安装／修复」），关掉终端后会话会从「进行中」移除；Mac 重启后，手机上开的 Grok 任务可以继续。Grok 的 Claude 兼容层不再执行 Claude 的审批门。
- 设置 › 诊断 › 观测健康加上了 Cursor 一行。
- 语音：批准、拒绝、回答、指示这四种动作，只有你在这一句里说出了任务名才会执行；供应商通话时长到顶时会说明原因，并可一键重拨。Gemini 已移除：之前选了 Gemini 的，语音伙伴会关闭，摘要需要重新选服务商，朗读改为跟随摘要。
- 卡住的命令行子进程都有了时间上限，不会再拖住 App。

Mac build 51。配套的 iPhone / Apple Watch 版本为 iOS 1.3.29（60）。

## English

**After updating, do this once:** open Settings › Agent CLIs › Maintenance and click Install / repair. This moves the hooks to a fixed folder, raises Claude's wait to 60 s, and wires up Grok's status line. If you use Codex, trust the hooks once more in Codex's `/hooks`; after that, app updates no longer need a re-trust.

- Lighter: the History archive is gone (its full-text index kept rebuilding), and the first launch deletes the old index to free disk space. 1.3.32 averaged about 11% CPU with one session working; 1.3.33 idles at about 1.5% and stays around 6% with 5–6 sessions working. The launch CPU burst and the menu bar's slow memory growth are fixed too. Live session reading stays. The `vibebuddy-mcp` tools that depended on the archive (sessions, projects, search, summary, index) are removed.
- Hooks are installed by the app itself, with no python3 needed, and the token no longer shows up in process arguments.
- Time to answer from the Watch: when nobody is at the Mac, Claude approvals and questions now wait up to 60 s (was 25 s). This needs the Install / repair step above.
- Claude: a turn with background tasks is no longer reported as done too early, and `/loop` turns stop re-alerting. Background sessions now come from the official `claude agents --json`. 1M-context sessions no longer show as 200k.
- Grok: context and cost are shown (for new sessions, after Install / repair), and closed terminals leave the working list. Grok tasks started from the phone can continue after the Mac restarts. Grok's Claude compatibility layer no longer runs Claude's approval gate.
- Settings › Diagnostics › Observation health now includes Cursor.
- Voice: approve, deny, answer and instruct only go through when you name the task in that sentence. A provider's call-length limit now ends the call with a reason and a one-tap redial. Gemini has been removed: if you had chosen it, the voice companion turns off, summaries need a provider again, and read-aloud follows your summaries.
- Stuck command-line child processes are time-limited and can no longer tie up the app.

Mac build 51. The accompanying iPhone / Apple Watch release is iOS 1.3.29 (60).

# VibeBuddy 1.3.33 — macOS

- 更省电：删掉了 History 会话存档（它的全文索引会反复重建），空闲时 CPU 从约 11% 降到 1.5%，启动时的 CPU 突发和菜单栏长时间运行的内存增长也一并修好。实时会话阅读保留。
- hook 安装改由 App 自己完成，不再需要 python3；脚本放在固定目录，App 更新后 Codex 不用重新信任。hook 调用 Mac 时，令牌不再出现在进程参数里。
- 手表来得及回答了：Mac 前没人时，Claude 的审批和提问最多等 60 秒（原来 25 秒）。已装过 hook 的用户，请在设置里点一次「安装 / 修复」让它生效。
- Claude：带后台任务的回合不再被误报为完成，`/loop` 的轮次不再反复提醒；后台会话改读官方 `claude agents --json`；1M 上下文的会话不再被显示成 200k。
- Grok：显示上下文与花费，关掉终端后会话会从「进行中」移除；Mac 重启后，手机上开的 Grok 任务可以继续。
- 设置里的观测诊断加上了 Cursor 一行。
- 语音：批准、拒绝、回答、指示这四种动作，只有你在这一句里说出了任务名才会执行；供应商通话时长到顶时会说明原因，并可一键重拨。Gemini 语音已移除。
- 卡住的命令行子进程都有了时间上限，不会再拖住 App。

Mac build 51。配套的 iPhone / Apple Watch 版本为 iOS 1.3.29（59）。

## English

- Lighter: the History archive is gone (its full-text index kept rebuilding). Idle CPU drops from about 11% to 1.5%. The launch CPU burst and the menu bar's slow memory growth are fixed too. Live session reading stays.
- Hooks are installed by the app itself, with no python3 needed. Scripts live in a fixed folder, so Codex stays trusted across app updates, and the token no longer shows up in process arguments.
- Time to answer from the Watch: when nobody is at the Mac, Claude approvals and questions now wait up to 60 s (was 25 s). If you installed hooks before, click Install / repair once in Settings to pick this up.
- Claude: a turn with background tasks is no longer reported as done too early, and `/loop` turns stop re-alerting. Background sessions now come from the official `claude agents --json`. 1M-context sessions no longer show as 200k.
- Grok: context and cost are shown, and closed terminals leave the working list. Grok tasks started from the phone can continue after the Mac restarts.
- Observation diagnostics in Settings now include Cursor.
- Voice: approve, deny, answer and instruct only go through when you name the task in that sentence. A provider's call-length limit now ends the call with a reason and a one-tap redial. Gemini voice has been removed.
- Stuck command-line child processes are time-limited and can no longer tie up the app.

Mac build 51. The accompanying iPhone / Apple Watch release is iOS 1.3.29 (59).

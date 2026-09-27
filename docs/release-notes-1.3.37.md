# VibeBuddy 1.3.37 — macOS

- Claude 的额度恢复显示。以前额度只来自 Claude Code 终端的状态栏（status line），而 Claude 桌面 App、IDE 插件里的会话不会运行状态栏，所以只在桌面 App 里用 Claude 时额度会一直停在旧读数。现在 VibeBuddy 大约每 15 分钟请官方 `claude` 命令行在后台发一次极小的请求（Haiku，约 0.0026 美元的等价额度），读出 5 小时和每周两个窗口的用量与重置时间。这个请求不会触发你的 hook，也不会留下会话记录，登录由 Claude Code 自己管理，VibeBuddy 不读取 Claude 的凭据。终端里有状态栏读数时仍优先使用它。
- 通过 Claude 应用网关设置的消费上限（`spend_limit`）超过 100% 时，现在显示为已用完，不再被忽略。
- 额度卡片上不再显示「状态栏未接入」：状态栏已不是 Claude 额度的唯一来源。

Mac build 55。配套的 iPhone / Apple Watch 版本仍为 iOS 1.3.30（63）。

## English

- Claude's allowance shows again. It used to come only from Claude Code's terminal status line, which sessions in the Claude desktop app and the IDE extensions never run, so working only in the desktop app froze the reading. VibeBuddy now asks the official `claude` CLI for one tiny headless request about every 15 minutes (Haiku, about a quarter of a cent of allowance) and reads the five-hour and weekly windows and their resets from it. The request fires none of your hooks and leaves no session behind; Claude Code keeps its own login and VibeBuddy never reads Claude credentials. A terminal status line reading still takes precedence while one is arriving.
- A gateway spend limit (`spend_limit`) past 100% now shows as spent instead of being ignored.
- Quota cards no longer say "Status line off": the status line is no longer Claude's only quota source.

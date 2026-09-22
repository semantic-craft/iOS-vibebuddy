# VibeBuddy 1.3.30 — macOS

- 继续压低 Mac 端空闲 CPU：工具账本不再每次工具调用都整份落盘（改为每 2 秒最多一次）；Grok 会话目录只在文件变动时重读；Cursor 项目目录名到检出路径的解析结果缓存 10 分钟；看板列表和项目标签在输入不变时不再重算。
- 以上都不改变任何界面行为，只减少重复工作。

包含 1.3.29 的全部修复。iPhone 对应版本仍为 iOS 1.3.25（55），无需更新。

## English

- Further idle-CPU reduction on the Mac: the tool ledger no longer rewrites its whole sidecar on every tool call (at most once per 2 s); a Grok session directory is re-read only when one of its files changed; a Cursor project directory name resolves to its checkout once per 10 minutes; the dashboard list and project labels are not recomputed while their inputs are unchanged.
- No visible behaviour changes; only repeated work removed.

Mac build 48. Includes all fixes from Mac 1.3.29. The accompanying iPhone release remains iOS 1.3.25 (55); no phone update is needed.

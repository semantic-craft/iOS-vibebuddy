# VibeBuddy 1.3.30 — macOS

- 继续压低 Mac 端空闲 CPU：工具账本不再每次工具调用都整份落盘（改为每 2 秒最多一次）；Grok 会话目录只在文件变动时重读；Cursor 项目目录名到检出路径的解析结果缓存 10 分钟；看板列表和项目标签在输入不变时不再重算。以上都不改变任何界面行为，只减少重复工作。
- 菜单栏图标不再自己消失：过去把图标从菜单栏拖出去、或菜单栏拥挤时系统把它移除，都会被当成"你关掉了它"永久记下来，而界面上没有任何地方能找回。现在只有设置页的开关能永久关闭它。
- 等待提醒的推送会顺带唤醒手机上的 app：手机在后台就能先探一次这台 Mac 通不通，把之前没送到的批准补发出去，或者在你对着空气点"批准"之前先告诉你链路断了。
- 批准接口接受手机带来的请求标识：同一个批准重发一次，会得到与第一次相同的结果，不会重复执行。

包含 1.3.29 的全部修复。配套的 iPhone 版本为 iOS 1.3.26（56）。

## English

- Further idle-CPU reduction on the Mac: the tool ledger no longer rewrites its whole sidecar on every tool call (at most once per 2 s); a Grok session directory is re-read only when one of its files changed; a Cursor project directory name resolves to its checkout once per 10 minutes; the dashboard list and project labels are not recomputed while their inputs are unchanged. No visible behaviour changes; only repeated work removed.
- The menu bar icon no longer disappears for good: dragging it out of the menu bar, or macOS removing the status item when the menu bar is crowded, used to be recorded as "you turned it off" — permanently, with nothing on screen to bring it back. Only the Settings toggle turns it off now.
- Waiting-cue pushes also wake the phone app in the background: it probes whether this Mac is reachable the moment the push lands, delivers any decision it was holding, and warns you when a tap could not reach this Mac — before you approve into the void.
- The approval endpoint accepts the request identifier the phone sends: the same approval delivered twice answers the second time exactly as it answered the first, instead of acting on it again.

Mac build 48. Includes all fixes from Mac 1.3.29. The accompanying iPhone release is iOS 1.3.26 (56).

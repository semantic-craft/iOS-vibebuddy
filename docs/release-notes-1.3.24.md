# VibeBuddy 1.3.24 — macOS

- 仪表盘侧边栏可拖拽调宽，也可收成仅图标的窄栏；宽度和折叠状态在重启后保留。
- 会话列表与阅读区之间的分隔条同样可拖拽：收到 72pt 窄条时每行只留代理图标和状态点，文字移入悬停提示；双击在窄条与完整宽度之间切换；⌘F 或窄条上的搜索图标会展开列表并把焦点放进搜索框。实时列表与历史共用同一宽度。
- 收件箱新增「Get started」卡片：挂接代理 CLI、获取 iPhone 应用（App Store 二维码与链接）、配对手机（内嵌连接码）。手机配对成功或手动隐藏后不再显示；未配对时，设置 › 设备与连接同样提供 App Store 卡片。
- 侧边栏麦克风与相邻图标对齐；审批条的 Approve 与 Deny 同高，更多授权选项的箭头恢复可见；阅读区底部的待办状态收成一行，禁用原因移入提示。
- 完成摘要改为先给出可执行的一步，再说结果；失败如实陈述，不再堆砌前后缀。
- 应用瘦身：DMG 28 MB → 18 MB，应用包 79 MB → 37 MB，仅保留 arm64 切片，崩溃日志仍可符号化。
- 完成判定与朗读修复：确认原生完成后再生成通知与朗读、已完成的朗读不再重播、离线手机的排队通知会被校验、空闲 Codex 对话恢复原生名称。

## English

- The dashboard sidebar resizes by drag and folds to an icon-only rail; its width and folded state survive a restart.
- The divider between the session list and the reader resizes the same way: at the 72 pt compact strip each row keeps its agent tile and state dot with the words in its tooltip, a double-click toggles the two shapes, and ⌘F or the strip's search glyph unfolds the list and focuses the field. Current tasks and History share one width.
- A **Get started** card in the Inbox covers the three setup steps: hook your agent CLIs, get the iPhone app (App Store QR and link), and pair the phone with an inline connection code. It goes away once a phone pairs or you hide it; while no phone is registered, Settings › Devices & connection carries the App Store card too.
- The sidebar's mic sits on the same glyph column as its neighbours; Approve and Deny match in height, the chevron for the wider grants is visible again, and the reader's pending-queue footer is one strip with the why-disabled sentence in its tooltip.
- Completion summaries lead with the one thing you can act on, then the result, and state failures plainly.
- Smaller download: DMG 28 MB → 18 MB, app bundle 79 MB → 37 MB, arm64 only, crash logs still symbolicated.
- Completion and speech fixes: notices and speech wait for native completion, finished speech no longer replays, queued notices for an offline phone are validated, and idle Codex conversations recover their native names.

Mac build 42. This release updates the Mac companion only; the iPhone half of the setup checklist ships with a separate iOS release.

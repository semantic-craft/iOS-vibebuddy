# VibeBuddy 1.3.18 — macOS

- 修复菜单栏图标因旧电脑或显示器保存的位置超出当前屏幕而不可见的问题。使用固定身份保存位置，迁移旧设置，并在启动时恢复无效位置。
- 保留有效的图标位置和用户主动隐藏的设置。显示器变化时校正保存的位置；实际排列由 macOS 管理，不承诺立即重新排列。
- 本次仅更新 Mac（build 30）；iPhone／Watch 的 TestFlight build 46 不变。

## English

- Fixed an invisible menu bar icon caused by a saved position outside the current display. A stable identity preserves placement, migrates legacy settings and repairs invalid positions at startup.
- Preserves valid positions and intentional hiding. Display changes repair the saved preference; macOS controls live placement.
- Mac-only release (build 30). iPhone and Watch TestFlight build 46 remain unchanged.

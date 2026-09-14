# VibeBuddy 1.3.17 — Mac, iPhone and Apple Watch

## 中文

- Watch 通知现在可打开对应任务详情，并在手机锁屏时主动获取最新结果。刷新失败时明确标示缓存内容并可重试；浏览和刷新不会自动标为已读。通知点击到最新详情已完成真实 Codex 任务的腕上验收。
- 移除真机体验不可靠的 Watch Recap。首页恢复可点击的运行中任务和未读结果；保留明确的“标为已读”操作。
- 修复任务提醒被前台应用误抑制的问题；关注任务完成时支持带声音的通知，仍遵守通知偏好和免打扰设置。
- iPhone 新增用量页面及主屏幕、锁屏额度小组件，展示现有服务商读数、更新时间和不可用状态；各服务商独立判断读数是否过期。点小组件可打开对应服务商的用量页面。
- iPhone 配对入口集中在“电脑连接”，首页连接圆点可打开配对入口；完善远程连接设置。
- Mac 会话阅读器改进正文更新、文件监听恢复、滚动跟随、搜索定位和导出。

## English

- Watch notifications open the matching task and request its latest result while the iPhone is locked. Failed refreshes clearly identify cached content and offer Retry. Viewing and refreshing do not mark a result read. The notification-to-current-detail path was accepted on a physical Watch using a real Codex task.
- Removed Watch Recap after unreliable device interaction. Working tasks and unread results remain directly accessible from Home, with explicit Mark as read.
- Fixed notification suppression based only on the source application being frontmost. Followed completions support audible notifications while retaining notification and Quiet preferences.
- Added iPhone Usage and home/lock-screen quota widgets, with per-provider freshness, reading age and unavailable states. Widget links select the relevant provider.
- Consolidated pairing under computer connection settings and the Home connection indicator; improved remote connection settings.
- Improved the Mac transcript reader's live refresh, file-watcher recovery, scrolling, search navigation and export.

## 范围与限制 / Scope and limits

- 额度小组件使用手机最近保存的读数，不承诺后台实时采集；服务商不可用或凭据过期时如实显示不可用。Watch 的主动任务刷新与额度小组件刷新是两条独立流程。
- Quota widgets use the phone's latest saved readings, not continuous background collection. Missing credentials or provider failures remain visible. Watch task refresh is separate from widget refresh.
- 本次 Watch 真机验收覆盖完成提醒、点击跳转和最新结果刷新；不代表所有审批、问答路径均已重新验收。

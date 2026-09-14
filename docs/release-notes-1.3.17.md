# VibeBuddy 1.3.17 — iPhone

## 中文

- iPhone 新增完整的 **Usage** 页面：首页左上角的柱状图按钮推入全屏页，Codex、Claude、Cursor、Grok Build、Grok Bot 依次列出每个额度窗口的剩余百分比、子弹图、重置倒计时和用量节奏（快于节奏时以琥珀色提示）；页首一行指出最紧的窗口，页底是今天与最近 7 天的本地 Token 花费。Mac 不可达时显示已保存读数的时间并淡化条形。
- 新增 **额度小组件**：桌面小号（选择一个供应商，大号剩余百分比加两根条）、桌面中号（五个供应商的周额度一览）、锁屏矩形与圆形。点击任一小组件直接打开 Usage 页并定位到对应供应商。
- 小组件只在 app 打开时更新数据，因此会标出读数的年龄；仅当 app 最后一次看到 Mac 不可达或读数超过一小时，数字才会淡化。

## English

- A full-screen **Usage** page on iPhone, pushed from the chart button on the home hub: every Codex, Claude, Cursor, Grok Build and Grok Bot window with what is left, a bullet bar, the reset countdown and its pace (amber when it is being used up faster than the clock). The first line names the tightest window; today's and the last seven days' local token spend close the page. When the Mac is unreachable, the page says how old the saved readings are and fades the bars.
- **Quota widgets**: a small home-screen widget for one provider of your choice, a medium overview of every provider's weekly allowance, and rectangular and circular lock-screen widgets. Tapping any of them opens the Usage page at that provider.
- Widgets only learn new readings while the app is open, so they print the reading's age and fade only when the phone last saw the Mac unreachable or the reading is more than an hour old.

## 范围与限制 / Scope and limits

- 不含 Token 花费小组件、大号小组件、多账号或 iCloud 同步；Mac 与 Watch 端无改动。
- 没有后台刷新：app 在后台时小组件保持最后一次读数。
- No token-spend or large widget, no multiple accounts or iCloud sync, and no Mac or Watch changes. There is no background refresh: widgets keep the last reading while the app is not running.

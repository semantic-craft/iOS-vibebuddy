# VibeBuddy 1.3.32 — macOS

- 配对里存下的远程地址如果根本不是一个合法主机名（比如一段被误存的空值或垃圾字符），Mac 端现在会直接丢弃它并让 iPhone 重新配对，而不是让手机拿着这个地址反复连接失败、界面上只显示"已断开"。
- 配套 iPhone / Apple Watch 版本 1.3.28（58）修好了"手机锁屏放口袋里、在手表上批准，Mac 要等手机解锁才收到"的问题；Mac 端不需要改动，但请一起更新手机。
- 清理了若干不再使用的内部代码，无界面变化。

Mac build 50。配套的 iPhone 版本为 iOS 1.3.28（58）。

## English

- A stored remote address that cannot be a hostname (a stray empty or garbage value) is now dropped on the Mac and the iPhone is asked to pair again, instead of the phone retrying that address forever behind a plain "Disconnected".
- The companion iPhone / Apple Watch release 1.3.28 (58) fixes approving from the Watch while the phone is locked in a pocket, which used to wait for the phone to be unlocked before the Mac heard the decision. Nothing changes on the Mac for it; update the phone alongside.
- Removed unused internal code; no visible change.

Mac build 50. The accompanying iPhone release is iOS 1.3.28 (58).

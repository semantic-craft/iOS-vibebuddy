# VibeBuddy 1.3.28 for iPhone and Apple Watch

## 简体中文

- 手机锁屏放在口袋里时，从手表批准不再要等到手机解锁才送达。9 月 22 日的真机验收里，手表上点了"批准"，Mac 三分半钟后、也就是手机解锁那一刻才收到。原因有两个：手表唤醒的手机因为实时连接还没恢复，把决定"暂存"起来，而暂存的决定只在 App 回到前台时才投递；并且手机在后台回复手表的这段时间没有向系统申请保活，手腕一放下就可能被挂起在半路。现在手机在收到手表的决定时立刻用保存的配对做一次投递（照旧先核对 Mac 自己的快照），手表直接听到"已批准"或"已不再等待"；只有 Mac 真的够不着时才暂存并提示。回复手表期间手机会申请后台运行时间。
- 保存的 Mac 地址如果不是合法主机名，会被丢弃并提示重新配对，而不是反复连接失败。

## English

- Approving from the Watch while the iPhone is locked in a pocket no longer waits for the phone to be unlocked. In the 2026-09-22 device round, a tap on the wrist reached the Mac three and a half minutes later, at the unlock. Two causes: the phone the wrist woke found its live stream not yet back and held the decision, and a held decision was only delivered when the app came forward; and the phone asked for no background time while it answered the wrist, so lowering the wrist could suspend it mid-request. The phone now runs one delivery pass at once, against the saved pairing and judged against the Mac's own snapshot as before, and the wrist hears "approved" or "no longer waiting" directly; a decision is held, and said so, only when the Mac really cannot be reached. The phone asks for background time while it answers the wrist.
- A saved Mac address that cannot be a hostname is dropped with a prompt to pair again, instead of failing to connect over and over.

iOS build 58. The accompanying Mac release is 1.3.31 (49).

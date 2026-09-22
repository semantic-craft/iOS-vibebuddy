# VibeBuddy 1.3.26 for iPhone and Apple Watch

## 简体中文

- 手表横幅上的批准 / 拒绝 / 回复，现在在你点的那台设备上执行。以前这三个动作是后台动作，按 Apple 的规则会跑在收到通知的 iPhone 上——口袋里锁着的手机连不上 Mac，点了也没人告诉你。现在它们都是前台动作：手表上点，手表打开对应卡片再发；手机横幅上点，手机打开对应会话（因此拒绝和回复需要先解锁手机，批准本来就需要）。送不出去时，卡片、标签页或空状态会直接说明原因并震动一下。
- 连不上 Mac 时，批准和回答会被留住而不是丢掉：每个目标最多留一个，等重新连上、推送唤醒 app，或你在收件箱新增的"暂存决定"条里点重试时，按同一个标识只送达一次。取消也在那里。
- 断连时会指名断在哪一环——Tailnet 没开、Mac 不可达、认证失败、地址无效、连接中断——显示在看板空状态和"设备与连接"里，并给一个"打开 Surge 或 Tailscale"的按钮。以前只有一句"已断开"。
- 保存的配对不会再莫名丢失：手机在后台启动、或首次解锁前读不到偏好设置时，不再把它当成"这台手机没配过 Mac"，回到前台会自动重读；退出演示模式不再删掉真实配对；未配对页面的"扫描配对码"不再清空磁盘上的数据。"设备与连接"里的断开连接现在会先确认（"忘记这台 Mac？"），配对读不出来时配对页会给出提示和"重试"。

## English

- Approve / Deny / Reply on a Watch banner now act on the device they are tapped on. They used to be background actions, which by Apple's rule run on the iPhone the notification was sent to — a locked phone in a pocket that could not reach the Mac, with nothing anywhere saying the tap was lost. They are foreground actions now: tapped on the Watch, the Watch opens the card and sends through it; tapped on the phone, the phone opens the session (so Deny and Reply need the phone unlocked, as Approve already did). When it cannot be sent, the card — or the tab pages, or the no-data screen — says why, with a haptic.
- A decision that cannot reach the Mac is held instead of dropped: approvals and answers only, one per target, delivered exactly once under the same key when the link comes back, when a push wakes the app, or from Retry on the new held-decisions strip in the Inbox. Cancel is there too.
- A broken link is named rather than described: Tailnet off, Mac unreachable, authentication, invalid address, or dropped — shown on the dashboard empty state and in *Device & connection*, with a one-tap "Turn on Surge or Tailscale". It used to say only "Disconnected".
- A saved pairing is no longer lost without anyone asking. A launch that could not read preferences — a background launch, or one before the first unlock — is no longer treated as "this phone has no Mac"; the app re-reads when it comes forward. Leaving the demo no longer touches the saved pairing, and "Scan pairing code" on the unpaired Usage page no longer erases it from disk. Disconnect in *Device & connection* now confirms first ("Forget this Mac?"), and the Connect screen shows a notice with Try again when a saved pairing could not be read.

iOS build 56. The accompanying Mac release is 1.3.30 (48).

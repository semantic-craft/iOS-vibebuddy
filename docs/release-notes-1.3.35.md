# VibeBuddy 1.3.35 — macOS

- 没有配置自己推送密钥的 Mac，现在也能在 iPhone 锁屏、App 没在运行时收到提醒：Mac 把提醒存进你自己的 iCloud 私有数据库，由 Apple 推到 iPhone（需要 iOS 1.3.30 (62) 及以上，两台设备登录同一个 Apple 账户）。提醒的标题和正文端到端加密，Apple 推送的只有通用文案；VibeBuddy 不运营服务器，也看不到你的 iCloud 数据。已经配了推送密钥的 Mac 照旧走原来的通道；没配时，设置里会多出「iCloud 提醒」一行，显示这条通道的状态。
- 用豆包或千问朗读时，新增三种主播风格：严肃、撒娇、诱惑，在朗读设置的「主播风格」里选，可以试听。风格会改变语气和措辞，中文朗读时还会换成专用音色（千问新加坡区除外）；最后一句保持平实，说清要你做的事或最终结果。原来的「邻家小妹」「火辣少女」已取消，自动改回「标准」。
- 较长的播报改为分段合成，不再因为超时或被截断而读不全；长播报会等所有分段合成完再开始播。
- 删除「回顾」（Recap）。任务的完成结果照常显示在任务里。iPhone 更新到 1.3.30 之前，旧版 iPhone 上的回顾会显示不可用。
- 无障碍：开着 VoiceOver 时，如果系统通知不会真正弹出（通知样式设为「无」，或只是临时授权），提醒改用刘海卡片并朗读，不再当作已送达。

Mac build 53。配套的 iPhone / Apple Watch 版本为 iOS 1.3.30（62）。

## English

- A Mac without its own push key can now reach your iPhone while it is locked and the app is not running: the Mac saves the alert to your own iCloud private database and Apple delivers it (needs iOS 1.3.30 (62) or later, with both devices on the same Apple Account). The alert's title and text are end-to-end encrypted, so Apple delivers only generic text; VibeBuddy runs no server and cannot read your iCloud data. A Mac that already has a push key keeps using it; one without a key shows a new "iCloud cues" row in Settings with this channel's status.
- With Doubao or Qwen read-aloud, there are three new announcer styles — Serious, Coquettish and Sultry — under "Announcer style" in the read-aloud settings, with a preview. A style changes the delivery and the wording, and for Chinese read-aloud also switches to a dedicated voice (except Qwen's Singapore region); the closing sentence is kept plain: what you need to do, or the final result. The old "Girl next door" and "Fiery girl" styles are gone and fall back to Standard.
- Longer read-alouds are synthesized in chunks, so they no longer time out or get cut off; a long one starts playing once every chunk is ready.
- Recap has been removed. Finished tasks still show their results. Until the iPhone is updated to 1.3.30, Recap on the older iPhone app shows as unavailable.
- Accessibility: with VoiceOver on, an alert whose system notification would not actually appear (alert style None, or provisional authorization) falls back to the notch card and is read aloud, instead of counting as delivered.

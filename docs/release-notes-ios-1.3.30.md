# VibeBuddy 1.3.30 for iPhone and Apple Watch

## 简体中文

- 如果你的 Mac 没有配置自己的推送密钥，现在也能经你自己的 iCloud 收到提醒：iPhone 锁屏、App 没在运行时照样会响，锁屏上可以直接批准，Apple Watch 上也能批准。提醒内容端到端加密，Apple 推送的只有通用文案。需要 Mac 1.3.35 及以上，两台设备登录同一个 Apple 账户。
- 用豆包或千问朗读时，新增三种主播风格：严肃、撒娇、诱惑，在「摘要与播报」的「主播风格」里选。中文朗读时还会换成专用音色（千问新加坡区除外）。原来的「邻家小妹」「火辣少女」已取消，自动改回「标准」。
- 较长的播报改为分段合成，不再因为超时或被截断而读不全。
- 删除 iPhone 上的「回顾」（Recap）。
- 「在外连接」改为以官方 Tailscale 为主：直接给出安装、登录步骤，并显示这台 iPhone 是否已接入 tailnet。自建 Headscale（在 Tailscale 里选自己的服务器）和 Surge 照旧可用；Tailscale 和 Surge 都装了时可以选用哪一个。部分运营商的蜂窝网络下，Tailscale 没开时现在会正确提示，而不是说连不上 Mac；设置步骤第一次打开时文字重叠的问题也已修正。

## English

- If your Mac has no push key of its own, alerts now reach you through your own iCloud: the iPhone rings while it is locked and the app is not running, you can approve from the Lock Screen, and Apple Watch can approve too. The alert's content is end-to-end encrypted, so Apple delivers only generic text. Needs Mac 1.3.35 or later, with both devices on the same Apple Account.
- With Doubao or Qwen read-aloud, there are three new presenter styles — Serious, Coquettish and Sultry — under "Presenter style" in Summary & speech. For Chinese read-aloud a style also switches to a dedicated voice (except Qwen's Singapore region). The old "Girl next door" and "Fiery girl" styles are gone and fall back to Standard.
- Longer read-alouds are synthesized in chunks, so they no longer time out or get cut off.
- Recap has been removed from iPhone.
- Connect away from home now leads with official Tailscale: install and sign-in steps, plus whether this iPhone is on your tailnet. Headscale (through Tailscale) and Surge still work; if you have both Tailscale and Surge, you can pick which one to use. On some carriers' cellular networks, the app now correctly says Tailscale is off instead of blaming the Mac, and the setup steps no longer show overlapping text the first time they open.

iOS build 63 (replaces build 62, withdrawn from App Review). The accompanying Mac release is 1.3.35 (53).

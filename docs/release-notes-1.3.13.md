# vibebuddy 1.3.13

- Connect the iPhone companion over Tailscale, including Headscale private IPv4 addresses, with saved endpoint settings and connection recovery.
- Discover GitHub Copilot CLI session history alongside Claude Code and Codex.
- Browse and search session history in the Mac workbench, with structured conversation reading, favorites, export, source-aware resume actions and AI summaries.
- Refine Qwen and Doubao voice personas and follow-up instructions.
- Improve audio recovery after Bluetooth and route changes, serialize call lifecycle transitions, and surface recovery or audio-release failures.
- Retain Watch approval notifications and actions, and validate the embedded Watch app's version, companion identity and distribution signature during packaging.

## 中文

- 支持通过 Tailscale 连接 iPhone，包括 Headscale 的私网 IPv4 地址，并保存连接设置、改进断线恢复。
- 在 Claude Code 和 Codex 之外，加入 GitHub Copilot CLI 的会话历史。
- Mac 工作台支持历史浏览与搜索、结构化对话阅读、收藏、导出、按来源恢复会话及 AI 摘要。
- 调整千问与豆包的语音角色及后续交互提示词。
- 改进蓝牙与音频路由切换后的恢复，统一通话启停顺序，并提示恢复或音频释放失败。
- 保留 Watch 审批通知与操作，在打包时检查内嵌 Watch 的版本、配对身份和分发签名。

## Requirements and limits / 使用条件与限制

- Tailscale or Headscale clients are configured outside VibeBuddy. Mac and iPhone must join the same private network; use the Mac's `100.x.x.x` address with Headscale.
- Copilot integration currently reads history; it does not provide live Copilot approvals or remote control.
- AI summaries require a configured provider. Resume actions depend on the source and provenance of the session.
- Background Watch notifications require the owner's APNs configuration with the correct push environment, an online phone and enabled notification mirroring. Watch notification routing and vibration also depend on device settings.
- Tailscale／Headscale 客户端需在应用外配置，Mac 与 iPhone 需接入同一私网；Headscale 使用 Mac 的 `100.x.x.x` 地址。
- Copilot 当前支持历史读取，不提供实时审批或远程控制。
- AI 摘要需要配置服务商；恢复会话的操作受会话来源和可验证信息限制。
- Watch 后台通知需要机主配置匹配环境的 APNs、手机保持联网并开启通知镜像；通知去向与震动还受设备设置影响。

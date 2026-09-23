# 08: 分发形态决策——Claude/Cursor 插件 vs Swift 安装器

**What to build:** 决策项。陌生 Mac 无 python3，愿景已定 Swift 重写安装器；评估另给出官方渠道：Claude 插件（`hooks/hooks.json` + `settings.json.subagentStatusLine`，唯一能穿过 `allowManagedHooksOnly`）、Cursor 插件（`cursor/plugins` 的 `hooks` 键）、Grok 全局 `~/.grok/hooks/*.json`（已是自有文件）。与 `.scratch/mac-app-store/` 的沙盒结论一起定：商店版 hooks 必须走 bundle 内路径、无 env 前缀。

**Blocked by:** None

**Status:** ready-for-human（需要用户拍板）

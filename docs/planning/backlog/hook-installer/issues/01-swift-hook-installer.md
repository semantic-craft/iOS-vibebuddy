# 01: Swift 安装器替换 python 安装脚本（C-1，吸收 AI-08）

**Status:** done（#266 已合并；验收各项都已勾选。第 41 行：owner 2026-09-24 信任后，App 从 main 重新部署了两次，Codex 仍然运行全部 14 条 hook）

**Executor:** Claude（Opus 实现）· branch `claude/c1-swift-hook-installer` · 2026-09-23

**Blocked by:** None

**Node:** C-1（`docs/planning/roadmap-2026-09.json` 的完整 prompt 仍是执行交接）

## 为什么

`VibeBuddyMacApp/Sources/HookSetup.swift` 用 `python3 hooks/install-*-hooks.py` 安装 hook；陌生 Mac 可能没有 python3。运行时的 hook 脚本（`vibebuddy-forward.sh`、`approval-hook.sh`、`vibebuddy-statusline.sh`、`cursor-followup.sh`）只依赖 `sh` 与 `curl`，所以把安装器移到 Swift 就彻底去掉 python 依赖。

## 分发形态决定（原 AI-08，2026-09-23 拍板）

Swift 安装器是主路径；Claude / Cursor 插件暂不做，只作为以后给"管理员强制启用插件"的组织的可选渠道。依据：

- 官方文档：`allowManagedHooksOnly` 同样拦截用户自己安装的插件，只放行管理员在 managed settings `enabledPlugins` 里强制启用的插件（code.claude.com/docs/en/hooks，`settings-reference#what-runs-under-allowmanagedhooksonly`）。原票"插件是唯一能穿过 allowManagedHooksOnly 的方式"不成立。
- 插件的 `settings.json` 只支持 `agent` 与 `subagentStatusLine`，装不了主 `statusLine`（plugins-reference），而配额读数依赖主状态行；装插件仍得改 settings.json，只会多出第二条安装路径。
- 同类成熟 Mac App 都在 Swift 里直接改配置：Octane0411/open-vibe-island（`ClaudeHookInstaller.swift`）、wxtsky/CodeIsland（`ConfigInstaller.swift`，约 15 家 agent）、sk-ruban/notchi（`HookInstaller.swift`）。

## 要做的

`HookInstaller`（MacCore，可测）覆盖 Claude、Codex、Grok、Cursor、OpenCode；`HookSetup` 改调它；python 安装脚本在迁移完成后删除（`codex_hook_trust.py` 的检查一并移入 Swift）。

必须满足（来自同类项目踩过的坑）：

1. **稳定的 hook 路径**：每次启动把 hook 脚本复制到 `~/Library/Application Support/vibebuddy/bin/` 并校验存在；配置里只写这个路径。命令字符串跨版本不变，Codex 按命令哈希记录的信任不会失效。（open-vibe-island#693：helper 没复制到记录的位置，hook fail-open，事件全部静默丢失。）
2. **可追溯的写入**：记录我们拥有的条目清单；写前带时间戳备份；原子写入。
3. **识别自己的条目**按命令匹配（含历史命令名），用于迁移旧门与卸载；卸载只删自己的条目。
4. **只写已安装版本认识的事件名**：按 `claude --version` 选择事件集。（vibe-notch#85：写入旧版不认识的 `PermissionDenied` / `PostCompact` / `StopFailure`，Claude 跳过了整个 settings.json。）
5. **statusLine 包装**：保存用户原命令，带防护，包装器永不把自己记为被包装者。（open-vibe-island#671：二次包装递归，机器上出现 4000+ 进程。）卸载时恢复原命令，找不到备份也不删除用户的 statusLine。
6. **尊重** `CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`GROK_HOME`。（open-vibe-island#237、CodeIsland#269。）
7. **记住用户的卸载**：更新后不自动重装。（open-vibe-island#324、#416。）
8. **Codex `config.toml`**：写入后能被解析，不留非法表。（CodeIsland#316：非法表让 Codex 拒绝整个文件。）Cursor `~/.cursor/hooks.json` 保留 `"version": 1`。

## 验收

- [x] 干净用户账户（无 python3 或 PATH 里没有）从 Settings 一键安装四家；各触发一次真实事件到 daemon。（2026-09-24 agent 模拟，不是真实 CLI 会话：临时 HOME + 去掉 python 的 PATH，不带参数跑 `vibebuddyd hooks install`，与设置页同一个 `HookInstaller.install()` 调用（检测已装 CLI、不加审批门），四家都检测到并装好；另用 `--approval` 装一遍，用配置里的原命令送样例事件，四家都到了隔离 daemon。设置页按钮本身在 E2E 模式下禁用，没点。见 backlog `roadmap-audit-2026-09-24.md`）
- [x] 已装旧 python 版本的机器升级后，旧条目被识别、迁移，无重复 hook；Codex 不要求重新信任（命令未变时）。
- [x] 卸载后 settings.json / hooks.json / config.toml 只剩用户自己的内容，statusLine 恢复原值；App 更新后不重装。（测试 `HookInstallerTests`：「install everything twice (byte-identical), approval, repair, uninstall: user content survives」「install wraps the status line keeping its fields; uninstall restores it exactly」「a tricky config.toml is byte-identical after install, approval and uninstall」「an explicit uninstall is remembered」；2026-09-24 端到端：卸载 Grok 后跑 `refreshOnLaunch`，只更新脚本，Grok 没被装回）
- [x] `HookInstaller` 测试覆盖：幂等、迁移、卸载、statusLine 防递归、事件名按版本过滤、`CLAUDE_CONFIG_DIR`。（「install everything twice (byte-identical)…」「bundle-path and checkout-path entries migrate…」「the wrapper never saves itself as the original…」「Claude events follow the installed version…」「CLAUDE_CONFIG_DIR, CODEX_HOME, CURSOR_HOME and XDG_CONFIG_HOME redirect…」；2026-09-24 `swift test --filter HookInstallerTests` 通过）

## Comments

- 2026-09-23 实现（PR 见 backlog README）：`HookInstaller`（VibeBuddyMacCore）取代全部 python 安装器，`vibebuddyd hooks install|uninstall|status` 供无 App 的用户使用；脚本复制到 `~/Library/Application Support/vibebuddy/bin/`；manifest + 带时间戳备份 + 原子写；Claude 事件按 `claude --version` 过滤；statusLine 防递归且无备份不删；尊重 CLAUDE_CONFIG_DIR / CODEX_HOME / GROK_HOME / CURSOR_HOME / XDG_CONFIG_HOME；记住卸载；Codex `config.toml` 不写（B-3），只读提示。已有用户：点一次 Install / Repair 迁到稳定路径，**Codex 需在 `/hooks` 重新信任一次**。
- 待验收（真机）：干净账户（无 python3）一键安装四家各收到真实事件；App 更新后不重装。
- 2026-09-23：#266 已合并并装机。本机 Claude、Grok 已迁到固定目录并验证（新路径转发事件被 App 收到）；Codex 待 owner 重新信任；干净账户验收待 owner。评审后续小项并入 backlog 的 C-1b。
- 2026-09-24：干净账户验收由 agent 在不新建系统账户的条件下模拟完成：临时 HOME（同时设 `CFFIXED_USER_HOME`），PATH 去掉 python，隔离 daemon 在 :18771。四家配置和脚本都到位，每家一个事件都送达，Claude 审批门正常，卸载 Grok 后模拟 App 更新（`refreshOnLaunch`）不会把 Grok 装回，真实 `~` 没被改动。明细见 `docs/planning/backlog/roadmap-audit-2026-09-24.md`，证据在 `~/Projects/_shared-work/iOS-vibebuddy/c1-clean-account-2026-09-24/`。第 41 行未勾：本机 Claude、Grok 已迁移（09-23），Codex 迁到固定路径后命令变了，需要 owner 在 `/hooks` 重新信任一次（见上面 09-23 的 Comments）。
- 2026-09-24：本机 Codex 已迁移。按设置页「修复」同样的调用跑了 `vibebuddyd hooks install --agent codex`，脚本来自 `/Applications` 的 bundle。`~/.codex/hooks.json` 的 14 条命令全部改指 `~/Library/Application Support/vibebuddy/bin/`，`config.toml` 没变。备份在 `~/Projects/_shared-work/iOS-vibebuddy/acceptance-2026-09-24/03-codex-migration/backup/` 和安装器自己的备份目录。迁移后 `hooks status` 报告 Codex「skipping 14 of 14」：信任之前 Codex 的 hook 事件和命令行审批拦截都不运行；会话和进度仍经 app-server / 转录读到（快照里 06:31Z 仍有 Codex 会话更新，来源是 appserver / transcript）。待办：owner 用 `/hooks` 信任；信任之后的下一次重新部署时，再确认 Codex 仍视 hook 为已信任。
- 2026-09-24：owner 在 Codex `/hooks` 信任了迁到固定目录的 14 条 VibeBuddy hook；`vibebuddyd hooks status` 显示「Codex is running all 14 VibeBuddy hooks」。验收最后一步：下一次从 `main` 重新部署后再跑一次 `vibebuddyd hooks status`，Codex 不应要求重新信任（命令字符串不变）。
- 2026-09-24（PERF-02 会话）：信任后的重新部署检查。11:00Z 从 main 43c52e0f 替换 `/Applications` 后，`vibebuddyd hooks status` 显示「Codex is running all 14 VibeBuddy hooks」；12:08Z 另一个会话又从 main 替换了一次（含 #301），之后再查，结果不变。命令字符串没变，Codex 没有要求重新信任，第 41 行已勾选。

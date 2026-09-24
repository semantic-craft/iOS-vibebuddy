# 路线图旧项核对 + C-1 干净账户模拟 + iOS 审核状态（2026-09-24）

范围：`docs/planning/roadmap-2026-09.json` 的 A-03、B-U、M-01、M-11、D-U、E-2、H-1、H-5；C-1 干净账户验收；iOS 1.3.28 (58) 审核状态。规则：agent 能用测试、日志、隔离 daemon、模拟器或 computer use 确认的，不交给 owner。

证据来源：`docs/qa/`、`docs/release-notes-*.md`、合并 PR 的正文和评论、ADR 修订、`git log`、归档包 `~/Projects/_shared-work/archive/iOS-vibebuddy-scratch-2026-09-23.tgz` 里的旧票和 `qa-shots`。归档包里没有 Claude 官方接入 01–06、codex-desktop-monitoring、mobile-watch-task-control 这几张票，也没有 `.scratch/qa-shots/{claude,codex,grok,cursor}/` 目录。所以 M-01、M-11 和 B-U 的 Claude 部分都没有原票可以勾选，只能按路线图 JSON 的规格核对。

## 结论

| 节点 | 结论 | 已有记录 | 缺什么 · 谁来做 |
|---|---|---|---|
| A-03 分类通知 | **部分覆盖** | 2026-09-06 基础验收：类别开关、强退后 APNs 送达、Mac 上的专注模式、跟进提醒（票 03 与 `qa-shots/notification-categories/acceptance-2026-09-06.md`，归档）。去重有 #54 的 Hermes 实测和 2026-09-21 集成发布记录（「phone channel skipped pushCovered」）。 | ① 漏接为 0：交给 H-2，在冻结候选上看漏接台账，由 agent 做。② 配额只在开关打开时推送、静音会话推无声横幅：本次跑了推送与通知相关测试（见下文「本次验证」），负载层面已确认。③ iPhone 专注模式下时效性提醒能否弹出、锁屏点批准要 Face ID：只能 owner 做，并入手表那一轮。票里「拒绝不要求解锁」这条已过时：ADR-0033 / iOS 1.3.26 起拒绝也会打开 App。 |
| B-U #42 真机验收 | **部分覆盖（真机证据很少）** | 回答 AskUserQuestion：真实 Claude CLI 经隔离 daemon 走通（#210、#211），模拟器上点了一次（#167）。Codex daemon 审批中继做过实测（#133）。HTTP 派活对 Claude、Codex、Cursor 都通过（#215），Codex 派活到达手机的 HTTP / WS 客户端（#216）。本机状态行转发已接上。 | 「Codex Desktop 审批到手机」不是验收缺口，是说法：Desktop 用自己的 app-server。README 第 33、83 行已经写明「原生 Desktop 审批可能仍需回到 Mac」，不再验收。其余都能由 agent 做，需要隔离 Mac App（E2E 配置）加 iPhone 模拟器或 iPhone Mirroring，已拆成单独的 agent 会话（见下文「交给 agent 的后续」）：配额 1 秒内更新、状态行字段、在场门控、`claude --bg` 后 `/jump` 接回、Desktop 跳转、`turn/steer`、新任务面板派 Claude 与 Codex、在手机界面回答问题。 |
| M-01 手表通知路由 | **部分覆盖** | 手机锁屏、戴着手表时通知到手腕：2026-09-21 R1 / R2 与 2026-09-23 手表门（`watch-gate-2026-09-23`）。手机解锁时通知到手机：2026-09-22 R2。 | ① 「是否重复」：由 agent 按提醒逐条读投递记录。② 手表没戴、手表戴着但锁定这两格：只能 owner 做，并入手表那一轮，多两步。 |
| M-11 跨端整体验收 | **受阻，范围已过时** | 它依赖的 M-09 已延后、M-10 已取消（2026-09-23）。已有：手机断网后恢复（`release-notes-ios-1.3.22.md`）；重复决策返回 409、已读跨端同步（`docs/qa/cross-device-1.3.5.md`）；Mac 重启后状态保留。 | agent 做：在场 / 离场、断联后的待定决策（ADR-0032）、跨端撤销、README 与上架文案只保留通过的能力、语音误识别（合成语音）。owner 做：专注模式、手表锁定、连点和 Mac 先拒，都并入手表那一轮，和 WR-06 重叠。 |
| D-U 三家耳测 | **部分覆盖** | OpenAI（GPT-Live）在 Mac 和 Hermes + AirPods 上都测过，owner 确认中文能听清、能打断（`docs/gpt-live-1-e2e.md`）。Qwen / 豆包有真实通话，owner 确认过（#147）。 | Gemini 上次耳测是 2026-06-05；英文一轮都没做过；到顶重拨在 D-1 会话里由 agent 验。用语音说「批准 / 拒绝 / 回答」再落到 Mac：agent 用合成语音接真实供应商验证。**只能 owner 做**：「听不听得清、能不能打断」只能靠耳朵，Gemini 和 Qwen 各打一通短电话，中英文各说一句。 |
| E-2 小尺寸图标 | **已覆盖（现有 PNG），E-1 之后重看** | 本次由 agent 渲染并判读：iPhone 图标在 40 / 60 px（通知）、58–120 px（Spotlight / 设置）大小下，猫脸、绿耳朵和眼睛都清楚。手表圆形图标在 48–100 px 下裁切正常。Mac 图标用已安装 App 的 Finder 图标检查（NSWorkspace 渲染 16–128 px），系统加了圆角方形且留边，没有灰色底框；16 px 时只看得出白色猫脸加绿点，这是这个尺寸的正常上限。截图在 `~/Projects/_shared-work/iOS-vibebuddy/e2-icon-check-2026-09-24/`。 | 不重拍 README 主图和截图，因为图标没变。E-1 分层图标做完后，agent 按同样方法再渲染一次。 |
| H-1 三家矩阵（Claude / Codex / Grok） | **部分覆盖** | Claude：在真机手机上批准过（`release-notes-ios-1.3.22.md`）；强退后完成提醒 APNs 送达（2026-09-06）。Codex：手机锁屏时手表打开过完成结果（1.3.17 记录）；Desktop 只验过完成和已读。Grok：在 Hermes 上批准和回答问题都做过（2026-09-21 集成验收）。三种状态：本次 C-1 模拟里四家的事件都在隔离 daemon 上变成 working / done，Claude 还走了一次审批门（needsResponse → allow）。 | agent 做：用 iPhone Mirroring 在手机上各批准一次；用 `devicectl … process terminate` 杀掉 App 后触发，看到 `apns accepted`。只能 owner 做：在手表上对 Claude、Codex、Grok 各批准一次，并入手表那一轮。Codex 要先在 `/hooks` 里信任，Grok 要用一个不是 always-approve 的工作区。 |
| H-5 Cursor 矩阵 | **部分覆盖** | 手表批准做过三次，都是托管 cursor-agent（ACP，CLI 路径）：2026-09-21 R1 / R2，2026-09-23 03:08 点横幅。状态都走过 working → permission → done。 | agent 做：手机批准（用 Mirroring）、杀掉 App 后 APNs 送达。只能 owner 做：在 Cursor IDE 的 agent 里输入一句无害的提示词。computer use 在 IDE 里只能点，不能打字，所以 IDE 路径得由 owner 触发，并入手表那一轮。 |

## C-1 干净账户（不新建系统账户的模拟）

环境：临时 HOME（同时设 `HOME` 和 `CFFIXED_USER_HOME`）里只建了 `.claude`、`.codex`、`.grok`、`.cursor` 四个空目录，模拟四家 CLI 已装、没有配置。PATH 是 `/bin`、`/usr/bin`、`/usr/sbin`、`/sbin` 的全部命令，只去掉 `python*` / `pip*`（`command -v python3` 返回 not found）。安装器用 `swift build` 出的 `vibebuddyd` 二进制，在 `env -i` 下运行，没有经过 `swift run`，因为 `swift` 本身要完整的 PATH。隔离 daemon 在 :18771（`apns: off`），doctor 全部通过。

| 步骤 | 结果 |
|---|---|
| `vibebuddyd hooks install --agent claude,codex,grok,cursor --approval` | 退出码 0。四份配置都写入了，所有命令都指向 `<HOME>/Library/Application Support/vibebuddy/bin/`；5 个脚本和 opencode 插件复制到位（755）；manifest 记录了四家。机器上没有 `claude`，所以 Claude 装的是 10 个状态事件，外加审批门和状态行，并提示装上 claude 之后重跑一次。Codex 提示需要在 `/hooks` 里信任。 |
| 每家一个事件，用配置里的原命令在同一个无 python 的 PATH 下执行 | Claude、Codex、Grok、Cursor 都在快照里变成 working；Stop 之后 Claude、Codex 变成 done。观测诊断里四家的 hook 都是 `healthy`（lifecycle、turn）。 |
| Claude 审批门（`approval-hook.sh`，PermissionRequest） | 卡片出现，`/decision allow` 之后 hook 输出 `{"behavior":"allow"}`。 |
| `hooks uninstall --agent grok` | Grok 的 `vibebuddy.json` 被删掉，`hooks-state.json` 记下 grok 是用户卸载的；其他三家不受影响。 |
| 模拟 App 更新：执行 App 启动时调用的 `HookInstaller.refreshOnLaunch()`（与 `HookSetup.refreshScriptsOnLaunch()` 同一段代码），脚本来源是一个内容已改动的新 bundle 目录 | 只有改动过的 `vibebuddy-forward.sh` 被更新。Claude、Codex、Cursor 的配置、manifest 和 state 的 sha256 都没变；**Grok 没有被装回**（状态仍是「uninstalled by you」）。再启动一次什么都不做。更新之后 Claude、Codex 的事件照常送达。 |
| 真实 `~` | `~/.claude/settings.json`、`~/.codex/hooks.json`、`~/.codex/config.toml`、`~/.grok/hooks/vibebuddy.json`、`~/Library/Application Support/vibebuddy/{hooks-manifest,hooks-state}.json`、`bin/*.sh` 在运行前后的 sha256 和 mtime 都一致，`~/.cursor/hooks.json` 始终不存在。唯一变化是 `~/.cursor/cli-config.json` 在 09:35:50 被改写：写它的是正在运行的 Cursor agent worker，VibeBuddy 代码里没有任何地方写这个文件。 |

没有覆盖到的：App 设置页「一键安装」这个按钮。E2E 运行配置会故意禁用安装（`HookSetup.run` 在 E2E 模式下直接返回），而第二个正式实例不允许启动。这个按钮调用的是同一个 `HookInstaller.install`，脚本来源是 bundle 里的 `hooks/`；2026-09-23 本机的 Claude、Grok 就是用这个按钮迁移到固定目录的（票 01 Comments）。结论：C-1 干净账户验收由 agent 完成，不再交给 owner。证据在 `~/Projects/_shared-work/iOS-vibebuddy/c1-clean-account-2026-09-24/`，不含 token。

## iOS 1.3.28 (58) 审核状态

没有查到。本机没有配置 App Store Connect API key（`~/.appstoreconnect/private_keys` 不存在；`xw-notary` 是 notarytool 的钥匙串配置，查不了审核状态）。Chrome 里 App Store Connect 的登录已过期：打开后被跳到 `login?…authResult=FAILED`，所以只读查看做不了，agent 不代为登录。最后一条记录是 2026-09-23 03:40 提交审核，当时状态为「可供审核」（Waiting for Review）。

## 本次验证

目标测试（`swift test --filter`）的结果见 PR 正文 Validation。Mac 端：NotificationDelivery、NotificationCoordinator、PresenceAndSteer、StatusLine、PhoneReceipts、MissedLedger、CodexAcceptanceScope、ActivityPush、VibeBuddyServer、HookInstaller。Kit 端：PushFanout、SoundPolicy、CompletionReminder、SessionAction、WatchApproval。

## 交给 agent 的后续（不交给 owner）

- **B-U / H-1 / H-5 / M-11 的 agent 部分**：隔离 Mac App（E2E 配置，非 9876）加 iPhone 模拟器或 iPhone Mirroring，逐项验证上表列出的内容；杀掉 App 后的 APNs 送达按 isolated phone acceptance recipe（:9877）在 Hermes 上做，要等手机空闲，不能和手表那一轮撞车。
- **A-03 漏接为 0**：并入 H-2。
- **D-U 语音动作**：用合成语音走 approve / deny / answer，接隔离 daemon。

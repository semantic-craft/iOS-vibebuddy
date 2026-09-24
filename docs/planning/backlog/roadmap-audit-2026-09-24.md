# 路线图旧项核对 + C-1 干净账户模拟 + iOS 审核状态（2026-09-24）

范围：`docs/planning/roadmap-2026-09.json` 的 A-03、B-U、M-01、M-11、D-U、E-2、H-1、H-5；C-1 干净账户验收；iOS 1.3.28 (58) 审核状态。规则：agent 能用测试、日志、隔离 daemon、模拟器或 computer use 确认的，不交给 owner。

证据来源：`docs/qa/`、`docs/release-notes-*.md`、合并 PR 的正文和评论、ADR 修订、`git log`、归档包 `~/Projects/_shared-work/archive/iOS-vibebuddy-scratch-2026-09-23.tgz` 里的旧票和 `qa-shots`。归档包里没有 Claude 官方接入 01–06、codex-desktop-monitoring、mobile-watch-task-control 这几张票，也没有 `.scratch/qa-shots/{claude,codex,grok,cursor}/` 目录。所以 M-01、M-11 和 B-U 的 Claude 部分都没有原票可以勾选，只能按路线图 JSON 的规格核对。

## 结论

| 节点 | 结论 | 已有记录 | 缺什么 · 谁来做 |
|---|---|---|---|
| A-03 分类通知 | **部分覆盖** | 2026-09-06 基础验收：类别开关、强退后 APNs 送达、Mac 上的专注模式、跟进提醒（票 03 与 `qa-shots/notification-categories/acceptance-2026-09-06.md`，归档）。去重有 #54 的 Hermes 实测和 2026-09-21 集成发布记录（「phone channel skipped pushCovered」）。 | ① 漏接为 0：交给 H-2，在冻结候选上看漏接台账，由 agent 做。② 配额只在开关打开时推送、静音会话推无声横幅：本次跑了推送与通知相关测试（见下文「本次验证」），负载层面已确认。③ iPhone 专注模式下时效性提醒能否弹出、锁屏点批准要 Face ID：只能 owner 做，并入手表那一轮。票里「拒绝不要求解锁」这条已过时：ADR-0033 / iOS 1.3.26 起拒绝也会打开 App。 |
| B-U #42 真机验收 | **agent 部分已验（上午，见文末）；状态行字段部分通过；Codex 的 steer 与额度推送受阻于 Codex 额度** | 回答 AskUserQuestion：真实 Claude CLI 经隔离 daemon 走通（#210、#211），模拟器上点了一次（#167）。Codex daemon 审批中继做过实测（#133）。HTTP 派活对 Claude、Codex、Cursor 都通过（#215），Codex 派活到达手机的 HTTP / WS 客户端（#216）。本机状态行转发已接上。 | 「Codex Desktop 审批到手机」不是验收缺口，是说法：Desktop 用自己的 app-server，README 已写明，不再验收。剩下：Codex 额度重置后重跑 steer、Codex 审批、`rateLimits/updated` 1 s（agent）；状态行被转录覆盖的缺陷见[票 10](agent-integration-2026-09/issues/10-transcript-overrides-statusline-window.md)。 |
| M-01 手表通知路由 | **部分覆盖** | 手机锁屏、戴着手表时通知到手腕：2026-09-21 R1 / R2 与 2026-09-23 手表门（`watch-gate-2026-09-23`）。手机解锁时通知到手机：2026-09-22 R2。 | ① 「是否重复」：由 agent 按提醒逐条读投递记录。② 手表没戴、手表戴着但锁定这两格：只能 owner 做，并入手表那一轮，多两步。 |
| M-11 跨端整体验收 | **范围已过时；agent 部分已验（上午，见文末）** | 它依赖的 M-09 已延后、M-10 已取消（2026-09-23）。已有：手机断网后恢复（`release-notes-ios-1.3.22.md`）；重复决策返回 409、已读跨端同步（`docs/qa/cross-device-1.3.5.md`）；Mac 重启后状态保留。 | agent 部分已完成。owner 做：专注模式、手表锁定、连点和 Mac 先拒，都并入手表那一轮，和 WR-06 重叠。 |
| D-U 三家耳测 | **合成语音已验（Gemini 英文、Qwen 中文，按轮次记录，见文末）；耳测仍由 owner 做** | OpenAI（GPT-Live）在 Mac 和 Hermes + AirPods 上都测过，owner 确认中文能听清、能打断（`docs/gpt-live-1-e2e.md`）。Qwen / 豆包有真实通话，owner 确认过（#147）。 | **只能 owner 做**：「听不听得清、能不能打断」只能靠耳朵。Gemini 和 Qwen 各打一通短电话，中英文各说一句；OpenAI 补一句英文（中文已测过）。OpenAI 和豆包的合成语音这次没跑（key 在钥匙串，读取可能弹密码框）。 |
| E-2 小尺寸图标 | **图标资源层面已覆盖（现有 PNG），E-1 之后重看** | 本次由 agent 渲染并判读：iPhone 图标在 40 / 60 px（通知）、58–120 px（Spotlight / 设置）大小下，猫脸、绿耳朵和眼睛都清楚。手表圆形图标在 48–100 px 下裁切正常。没在真机的通知和 Spotlight 里看。Mac 图标用已安装 App 的 Finder 图标检查（NSWorkspace 渲染 16–128 px），系统加了圆角方形且留边，没有灰色底框；16 px 时只看得出白色猫脸加绿点，这是这个尺寸的正常上限。截图在 `~/Projects/_shared-work/iOS-vibebuddy/e2-icon-check-2026-09-24/`。 | 不重拍 README 主图和截图，因为图标没变。E-1 分层图标做完后，agent 按同样方法再渲染一次。 |
| H-1 三家矩阵（Claude / Codex / Grok） | **agent 部分已验（Claude、Grok；Codex 受阻于额度，见文末）** | Claude：在真机手机上批准过（`release-notes-ios-1.3.22.md`）；强退后完成提醒 APNs 送达（2026-09-06）。Codex：手机锁屏时手表打开过完成结果（1.3.17 记录）；Desktop 只验过完成和已读。Grok：在 Hermes 上批准和回答问题都做过（2026-09-21 集成验收）。三种状态：本次 C-1 模拟里四家的事件都在隔离 daemon 上变成 working / done，Claude 还走了一次审批门（needsResponse → allow）。 | agent 部分已完成：手机批准是在 iPhone 模拟器上点的（没用 Mirroring），杀 App 后的 APNs 在 Hermes 上验。剩下：Codex 额度重置后补一次手机批准（agent）；只能 owner 做：在手表上对 Claude、Codex、Grok 各批准一次，并入手表那一轮。Codex 要先在 `/hooks` 里信任，Grok 要用一个带 `ask` 规则的工作区（owner 的 Grok 是 always-approve）。 |
| H-5 Cursor 矩阵 | **agent 部分已验（见文末）** | 手表批准做过三次，都是托管 cursor-agent（ACP，CLI 路径）：2026-09-21 R1 / R2，2026-09-23 03:08 点横幅。状态都走过 working → permission → done。 | agent 部分已完成（手机批准在模拟器上点，APNs 在 Hermes 上验）。只能 owner 做：在 Cursor IDE 的 agent 里输入一句无害的提示词。computer use 在 IDE 里只能点，不能打字，所以 IDE 路径得由 owner 触发，并入手表那一轮。 |

## C-1 干净账户（不新建系统账户的模拟）

环境：临时 HOME（同时设 `HOME` 和 `CFFIXED_USER_HOME`）里只建了 `.claude`、`.codex`、`.grok`、`.cursor` 四个空目录，模拟四家 CLI 已装、没有配置。PATH 是 `/bin`、`/usr/bin`、`/usr/sbin`、`/sbin` 的全部命令，只去掉 `python*` / `pip*`（`command -v python3` 返回 not found）。安装器用 `swift build` 出的 `vibebuddyd` 二进制，在 `env -i` 下运行，没有经过 `swift run`，因为 `swift` 本身要完整的 PATH。隔离 daemon 在 :18771（`apns: off`），doctor 全部通过。

| 步骤 | 结果 |
|---|---|
| `vibebuddyd hooks install --agent claude,codex,grok,cursor --approval`（事件都是样例数据，不是真实 CLI 会话：干净 HOME 里的 CLI 没有登录） | 退出码 0。四份配置都写入了，所有命令都指向 `<HOME>/Library/Application Support/vibebuddy/bin/`；5 个脚本和 opencode 插件复制到位（755）；manifest 记录了四家。机器上没有 `claude`，所以 Claude 装的是 10 个状态事件，外加审批门和状态行，并提示装上 claude 之后重跑一次。Codex 提示需要在 `/hooks` 里信任。 |
| 每家一个事件，用配置里的原命令在同一个无 python 的 PATH 下执行 | Claude、Codex、Grok、Cursor 都在快照里变成 working；Stop 之后 Claude、Codex 变成 done。观测诊断里四家的 hook 都是 `healthy`（lifecycle、turn）。 |
| 不带参数的 `vibebuddyd hooks install`（设置页按钮的同一调用：检测已装 CLI、不加审批门），换一个新的干净 HOME | 检测到 claude、codex、grok、cursor，跳过 antigravity、opencode；四家都装好，`status` 显示四家 hooks installed，Claude 状态行已接上。 |
| Claude 审批门（`approval-hook.sh`，PermissionRequest） | 卡片出现，`/decision allow` 之后 hook 输出 `{"behavior":"allow"}`。 |
| `hooks uninstall --agent grok` | Grok 的 `vibebuddy.json` 被删掉，`hooks-state.json` 记下 grok 是用户卸载的；其他三家不受影响。 |
| 模拟 App 更新：执行 App 启动时调用的核心方法 `HookInstaller(environment: .live(), …).refreshOnLaunch()`（与 `HookSetup.refreshScriptsOnLaunch()` 同一核心调用，但没经过 App 包的 `Bundle.main`、E2E 检查和后台 Task），脚本来源是一个内容已改动的新 bundle 目录 | 只有改动过的 `vibebuddy-forward.sh` 被更新。Claude、Codex、Cursor 的配置、manifest 和 state 的 sha256 都没变；**Grok 没有被装回**（状态仍是「uninstalled by you」）。再启动一次什么都不做。更新之后 Claude、Codex 的事件照常送达。 |
| 真实 `~` | `~/.claude/settings.json`、`~/.codex/hooks.json`、`~/.codex/config.toml`、`~/.grok/hooks/vibebuddy.json`、`~/Library/Application Support/vibebuddy/{hooks-manifest,hooks-state}.json`、`bin/*.sh` 在运行前后的 sha256 和 mtime 都一致，`~/.cursor/hooks.json` 始终不存在。唯一变化是 `~/.cursor/cli-config.json` 在 09:35:50 被改写：写它的是正在运行的 Cursor agent worker，VibeBuddy 代码里没有任何地方写这个文件。 |

没有覆盖到的：App 设置页「一键安装」这个按钮。E2E 运行配置会故意禁用安装（`HookSetup.run` 在 E2E 模式下直接返回），而第二个正式实例不允许启动。这个按钮调用的是同一个 `HookInstaller.install`，脚本来源是 bundle 里的 `hooks/`；2026-09-23 本机的 Claude、Grok 就是用这个按钮迁移到固定目录的（票 01 Comments）。结论：C-1 干净账户验收由 agent 完成，不再交给 owner。证据在 `~/Projects/_shared-work/iOS-vibebuddy/c1-clean-account-2026-09-24/`，不含 token。

## iOS 1.3.28 (58) 审核状态

没有查到。agent 请求读取 Mail / Outlook 里 Apple 的状态邮件，被拒绝。本机没有配置 App Store Connect API key（`~/.appstoreconnect/private_keys` 不存在；`xw-notary` 是 notarytool 的钥匙串配置，查不了审核状态）。Chrome 里 App Store Connect 的登录已过期：打开后被跳到 `login?…authResult=FAILED`，所以只读查看做不了，agent 不代为登录。最后一条记录是 2026-09-23 03:40 提交审核，当时状态为「可供审核」（Waiting for Review）。

## 本次验证

目标测试（`swift test --filter`，2026-09-24，本分支所基于的 main）全部通过，没有跳过：Mac 160 项 / 14 个 suite（NotificationDelivery、NotificationCoordinator、PresenceAndSteer、StatusLine、PhoneReceipts、MissedLedger、CodexAcceptanceScope、ActivityPush、VibeBuddyServer、HookInstaller）；Kit Swift Testing 75 项（PushFanout、SoundPolicy、CompletionReminder、SessionAction）加 XCTest 40 项（WatchApprovalTests）。

## 交给 agent 的后续：结果（2026-09-24 上午 10:00–11:00）

B-U、H-1、H-5、M-11、D-U 的 agent 部分已跑完，基于 main `ebd06396`，没有改 App 代码。

**受阻：Codex 那几项。** owner 的 Codex 周额度已用完（`account/rateLimits/read`：100%，`rate_limit_reached`，9 月 25 日 9:00 重置）。账户里有一张「Full reset」免费重置券，agent 的建议是不用，等自动重置后再补测，所以没有列进 owner 清单。

**要请 owner 知道的一件事：Hermes 多收了 28 条测试推送。** 约定的窗口是 10:39–10:45，但窗口结束后验收服务仍开着 APNs、仍登记着 Hermes 的 token。10:48–10:59 做 D-U 时，它向 Hermes 推了 26 条审批和问题提醒，项目名是 apple、桃子这类水果；另有 10:50 的 2 条完成提醒。APNs 都是 accepted。手表会话 10:45 重装的是同一个 bundle 的开发版，所以这些推送很可能到了 owner 的手机和手表上。11:00 服务已停，已告知手表会话：这些不算手表那一轮的观察。以后约定窗口一结束，就把设备从验收服务的登记里删掉，或用 `apns=off` 重启服务。

### 环境

- **隔离验收服务 `buharness`**：放在草稿包里，端口 :18791。
  - 它照 `MenuBarModel.startServer` 的接线装配 `VibeBuddyServer`，用的是正式闭包：在场判断按 `presenceInput` 的同一公式，还有终端跳转、Desktop 跳转、后台会话接回、四家派活、实时额度 → `providerQuota`。
  - APNs 走的是 `vibebuddyd` 那一路：pusher 交给 server，由 server 推待回应提醒。正式菜单栏 App 传的是 `pusher: nil`，由 `startPolling` 推送。所以这里证明的是「手机被杀后能收到」，没验菜单栏 App 的触发路径。
  - 在场判断读的是 store 快照；正式 App 读的是每 2 s 轮询一次的会话列表。这对本次结果没有影响。
  - `CFFIXED_USER_HOME` 指向一次性目录，令牌、账本、设备登记、`apns.json` 都在那里。`HOME` 保持真实值，因为 `claude`、`codex`、`grok`、`cursor-agent` 要用 owner 的登录。
  - 前后核对了真实 `~` 下的配置 sha256，VibeBuddy 写的文件都没变。有两处变化不是本次造成的：`~/.cursor/cli-config.json` 由常驻的 Cursor worker 定期改写（C-1 时也见过）；正式 App 的 `device-registry.json` 在 10:59 更新，是手表会话重装后，手机向 :9876 重新登记。
- **不用 E2E Mac App 的原因**：E2E 模式下跳转和接回直接返回 `noTerminal`，也不接实时额度，这几项在它上面测不了。
- **iPhone**：自建的模拟器 `BU Roadmap Phone QA`（iOS 27），用启动环境变量配对到 :18791。点按用草稿里一个极小的 XCUITest 驱动完成，因为模拟器面板没有授权，computer use 又被别的会话占着。
- **Hermes**：只打算做「杀掉 App 后 APNs 送达」。多收的推送见上文。
- **证据和源码**：在 `~/Projects/_shared-work/iOS-vibebuddy/roadmap-agent-acceptance-2026-09-24/`，一次性令牌、Codex 账户 id 和重置券 id 都已脱敏。
  - `kit/` 里的脚本写死了本会话的草稿路径和 worktree 路径。重跑时从 `kit/` 重建，先改这两个路径。
  - 下表中注明「未另存」的数字，来自本会话的命令输出。

### 结果

| 项 | 结果 | 依据 |
|---|---|---|
| Codex 探针 `probe.py audit` | review | daemon 0.153.4，CLI 0.156.1。VibeBuddy 的 14 条 hook 全是 `modified`，等 owner 在 `/hooks` 里重新信任（「只剩你」第 2 件）；11:20 重跑的结果另存为 `bu/codex-probe-audit-rerun-1120.jsonl`。客户端方法和必填字段都齐。`~/.codex/config.toml` 的默认模型是 `gpt-6-astra`；这次 turn 失败的原因是额度用完，不是模型 |（2026-09-24 已信任，`hooks status` 显示 14 条全部运行，见 README「只剩你」第 3 件）
| B-U 配额 1 秒内更新 | **Claude 通过；Codex 受阻** | Claude：状态行送到 `/statusline`，约 0.1 s 后快照里出现配额（10:10:39.659 → .755，50 ms 轮询）。这是第一次读数：从「Collection is turned off」变成有值，不是数值变化。Codex：额度用完，不会发 `account/rateLimits/updated`。监听了 90 s（未另存），一条都没收到（文件只记收到的事件）。启动时 `rateLimits/read` 的结果正常进了快照：剩余 0%，重置时间正确 |
| B-U 状态行字段 | **部分通过：能写入，但会被转录覆盖** | 真实 Claude 2.1.281 会话，10:10–10:11 状态行把显示名「Opus 5.5 (1M context)」、`effort` medium、`contextWindow` 1000000、费用和增删行数写进了会话行，statusline 来源 `healthy`；5 h 和 7 天两个窗口进了 `providerQuota`。到 10:13 的快照里，同一会话变成 `claude-opus-5-5`、窗口 200000：读转录时 `SessionReducer.enrich` 用型号表把它们改掉了。1M 上下文的会话因此在两次状态行之间显示约 20% 占用，实际约 4%。开了[票 10](agent-integration-2026-09/issues/10-transcript-overrides-statusline-window.md) |
| B-U / M-11 在场门控 | **通过（两种判定都验了）** | 离开：前台是 Claude 桌面 App → `away`，卡片交给手机，可回答。在场：Terminal 在前台，会话的 tmux 窗格就在这个 Terminal 里，空闲 0 s → `present`；卡片 `answerable:false`，Claude 立即在本地弹出询问。空闲超过 120 s 一律判离开；owner 不在时，用一个原位、零位移的鼠标移动事件把空闲清零（见 `bu/harness.log` 的 presence 行） |
| B-U 新任务面板派 Claude | **通过** | 在手机「New task」面板选 Claude Code、名字填 `bu-dispatch-claude` → `claude --bg`，会话 `7eb77dae…` 出现在快照并完成 |
| B-U `claude --bg` 后 `/jump` | **通过** | 返回 `{"outcome":"attached"}`，用时 0.27 s；Terminal 新开了 `claude attach 7eb77dae` 窗口 |
| B-U Codex Desktop 跳转 | **通过** | 对 Codex 线程调 `/jump` → `focused`，前台变成 `com.openai.codex`（ChatGPT 窗口） |
| B-U 新任务面板派 Codex | **派活通过；turn 受阻** | 面板切到 Codex → 建了线程 `01a0d13e…`；turn 立即失败，手机上如实显示「Turn failed: You've hit your usage limit …」。HTTP 派活同样建了线程（0.27 s，未另存）。两个测试线程已归档 |
| B-U `turn/steer` | **受阻（额度）** | 没有能运行的 turn，也就没有可以 steer 的对象。目前只有 `PresenceAndSteerTests` 覆盖，没有端到端记录，README 已照实写明 |
| B-U 手机界面回答 AskUserQuestion | **通过** | 真实 Claude 会话问「Which color…」，在手机上点 Blue → Claude 收到「Blue」，写出内容为 Blue 的 `color.txt`。卡片只保留约 25 s（hook 的 hold），前两次驱动太慢、超时，第三次成功 |
| H-1 手机批准 · Claude | **通过（模拟器）** | 真实 Claude 会话要执行 `touch bu-phone-approved.txt`，在手机卡片上点 Approve 后文件生成 |
| H-1 手机批准 · Grok | **通过（模拟器，要加项目级规则）** | owner 的 `~/.grok/config.toml` 是 `permission_mode = "always-approve"`，托管的 Grok 任务从不询问，前两次都直接执行了。在已受信任的 `~/Projects` 下建工作区，项目级 `.grok/config.toml` 写 `[permission] ask = ["Bash(touch *)"]` 后出现卡片；手机批准后文件生成。只写 `permission_mode = "default"` 不够 |
| H-1 手机批准 · Codex | **受阻（额度）** | 没有能运行的 turn，就不会有审批请求 |
| H-5 手机批准 · Cursor | **通过（模拟器）** | 托管 cursor-agent（ACP）要执行 `touch`，在手机上点 Approve 后文件生成 |
| H-1 / H-5 杀掉 App 后 APNs | **通过（Claude、Grok、Cursor）** | Hermes 装 main 的 Debug 版，用启动环境变量指向 :18791 并登记 token，然后 `devicectl … process terminate`。三家审批推送都是 `apns accepted`（10:43:47、10:43:50、10:43:59）。触发前先关掉模拟器里的 App，免得它的回执让推送被跳过 |
| M-11 断联后的待定决策（ADR-0032） | **通过** | 手机经一个可随时断开的转发连到服务。App 在前台、已知离线时，按钮是灰的（「Offline · replies are unavailable」）。断开时在审批横幅上点 Approve，通知变成「Approve for a task is on hold · Can't reach your Mac … will send it as soon as it can」，Mac 上的卡片仍在等待。恢复链路、App 回到前台，约 3 s 后自动补投（10:40:54 → 10:40:57，未另存），Cursor 执行了命令（`bu/m11-held-after-reconnect.png`） |
| M-11 跨端撤销 | **通过** | 手机打开卡片，另一端 `POST /decision allow` → 200；3 s 内手机撤下按钮，显示「Read — confirmed by Mac」；再发一次决策返回 409 |
| M-11 语音误识别 | **本轮没有落错，但属于侥幸** | Qwen 第 1 轮：说的是「拒绝 grape」，模型发了 `deny_session(orange)`。被拒的原因是 orange 的卡片已经超时消失，不是复核发现目标不对；如果 orange 还挂着（比如没有 25 s 超时的 Cursor 审批），这次拒绝就会落到别的任务上。`answer_session(cherry)` 被拒，是因为有两个同名 cherry 会话。见下面发现 1 |
| M-11 README / 上架文案 | **已核对** | 今天通过的能力（Claude / Grok / Cursor 手机批准、语音批准 / 拒绝 / 回答、Desktop 跳转、派活）和文案一致。README 改了两处：Codex steer 标为未经端到端验证；Grok 行写明托管任务在 `always-approve` 下不会询问。上架文案没有写 steer 或 Grok，不用改 |
| D-U 合成语音 · Gemini（英文） | **第 4 轮 3/3；前 3 轮各有失败** | `say` 合成 16 kHz 语音，送进真实 `gemini-3.1-flash-live-preview`，走 `VoiceCallCoordinator`，再照手机 `performVoiceAction` 的同一映射复刻（`VoiceSessionMatch` → `/decision` / `/answer`，没有调用 App 本身的 `decideConfirmed`）。卡片是 `/approval` 造的合成 hook，不是真实 agent。第 4 轮：批准 kiwi → allow，拒绝 melon → deny，回答 papaya → 「blue」，都由挂着的 hook 收到。第 1 轮只有回答成功：批准那句在会话建好之前就发了，模型只查了状态；拒绝 banana 没有任何工具调用，没留转写，原因不明。第 2 轮三项都被拒：项目名和第 1 轮重名，按设计拒绝。第 3 轮：批准 mango 在会话建好前发出、没有工具调用，拒绝和回答成功。第 4 轮改为连上后等 2 s 再说 |
| D-U 合成语音 · Qwen（中文） | **第 4 轮 3/3；前 3 轮 0/3** | `qwen-audio-3.0-realtime-plus`。第 4 轮：批准 桃子 → allow，拒绝 李子 → deny，回答 橘子 → 「蓝色」。第 1 轮用英文项目名，识别听错（orange→「波动」、grape→「高客」、lemon→「任务」），模型改发别的目标，见上一格。第 2 轮说「西瓜项目」，模型没先查状态就把「项目」拼进了名字，匹配不上被拒；「樱桃」听成了「英超」。第 3 轮转写完全正确（「批准葡萄的请求」「拒绝菠萝的请求」），但批准那步模型只查了状态，拒绝那步没有任何工具调用；回答发给了 cherry，被拒 |

### 发现（本次没有修；1 开了 realtime-verify 票 03，2 开了票 10）

1. **语音模型会对没点名的任务下手，App 挡不住「另一个有效目标」**（[realtime-verify 票 03](realtime-verify/issues/03-voice-action-names-a-different-waiting-task.md)）。 Qwen 第 1 轮把「拒绝 grape」发成了 `deny_session(orange)`。`VoiceSessionMatch` 和 App 的复核只拦得住对不上号或不唯一的名字；模型点名另一个仍在等待的任务时，动作会被执行。第 4 轮的输入转写是「批准调整的请求」「拒绝你这个请求」，模型给出的项目名却是正确的 桃子、李子。这份转写和模型实际听到的是不是同一路输入，代码里没有说明，所以分不清模型是听对了，还是按唯一候选猜的。
2. **转录读取覆盖状态行的上下文窗口和型号**，见[票 10](agent-integration-2026-09/issues/10-transcript-overrides-statusline-window.md)。
3. **Qwen 会漏掉明确的指令**：第 3 轮转写正确，模型却没有发动作。
4. **Claude 的审批和问题在手机上只停留约 25 s**（`approvalTimeout`），过了就只能在 Mac 上回答。这是设计如此，但手机端在卡片消失前没有倒计时提示。
5. **手机任务页的标题是会话的第一条提示词**（如「Reply with just the word OK.」），卡片其实属于后面的一条命令。
6. **Cursor 卡片的命令预览带反引号**（`` `touch …` ``），来自 ACP 的标题。
7. 用 `/approval` 造的 AskUserQuestion 卡片，在 hook 超时后仍停在 needsResponse。只在合成会话上见到，真实会话没复现。

### 还剩的 agent 部分

- Codex 的 steer、手机批准、`rateLimits/updated` 1 s：9 月 25 日 9:00 额度重置后，用 `kit/` 重建验收服务再跑一次。
- 票 10：修状态行被覆盖的问题。
- realtime-verify 票 03：先定方案，再改语音动作的目标确认。
- A-03 漏接为 0：仍并入 H-2。

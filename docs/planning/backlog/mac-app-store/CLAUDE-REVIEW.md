# MAS-01 独立评审：沙盒商店版能还原多少 GitHub 版体验

作者：Claude Code（独立评审）。日期：2026-09-07。基线 `053a87b`，`main` 与 origin 同步、工作区干净。
环境：macOS 26.6.2 (25G83)、Xcode 26.6、Swift 6.3.3。

本文件包含**本机实测**结果，不只是文档推断。实测用隔离的探针 app（自建 bundle、独立 bundle ID、Apple Development 证书签名），
没有改动、重启或替换任何正在运行的 vibebuddy 实例、hooks 或用户代理配置。

---

## 1. 结论先行

**完整迁移不可能；"核心体验"可以保住大约七成，但要换一套接线方式。**

能保住的核心闭环是：**观察真实 Claude Code / Codex CLI 任务 → 通知 → 手机/Mac 审批与问答 → 代理真的执行**。
现有 probe5 仅证明外部 HTTP 入站与回包前提成立；真实 agent → iPhone → agent 后续行为尚未测，必须通过票 13，不能称逐段闭环已验收。

必然失去的是三类"从 Mac 出去控制别人"的能力：

1. **Codex app-server Unix socket**——沙盒硬禁止，且 Apple 明说没有合法绕法。连带失去 Codex Desktop 的审批/问答、实时额度、从手机新建/steer Codex 线程。
2. **启动和控制外部 CLI**——`claude`、`codex`、`tmux`、`python3` 全都执行不了（实测），所以"从手机派新任务给 Claude"和"跳转到具体终端标签页"在商店版没有合规实现。
3. **Sparkle 自动更新**——规则明文禁止，必须换成商店更新。

原 spec 的判断里：**"路线 B 值得优先验证"是对的**，但它把 Codex socket 列为"未知"过于乐观——这一条现在可以判定为**确定不行**；
反过来它对 Claude hooks 过于保守——hooks 这条路**实测可以完整穿过沙盒边界**，包括阻塞式审批的应答。

---

## 2. Apple 的硬性规则（原文与出处）

来自 [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)：

- **2.4.5(i)**：必须适当沙盒化，并且"should also only use the appropriate macOS APIs for modifying user data stored by other apps"。
- **2.4.5(ii)**：必须是"self-contained, single app installation bundles and cannot install code or resources in shared locations"。
- **2.4.5(iv)**：不得下载或安装独立 app、kext、附加代码或资源来增加功能。
- **2.4.5(vii)**：必须用 Mac App Store 分发更新，"other update mechanisms are not allowed"。→ Sparkle 出局。
- **2.5.2**：应在自己的 bundle 内自包含，"may not read or write data outside the designated container area"。

Unix domain socket，Apple DTS (Quinn) 的明确表态，[Developer Forums 788364](https://developer.apple.com/forums/thread/788364)：

> "they are blocked by the sandbox as part of its general policy of blocking unmediated IPC between code from different teams."
> "entitlements like `com.apple.security.temporary-exception.files.absolute-path.read-write` only work for files and directories; they don't work for Unix domain sockets."

并给出结论：App Store 分发**没有可支持的绕法**，要用就直接分发（Developer ID）。

Apple Events 临时例外，[Developer Forums 663311](https://developer.apple.com/forums/thread/663311)，审核实际拒信：

> "The following temporary entitlement exceptions requested for this app are not appropriate and will not be granted:
> `com.apple.security.temporary-exception.apple-events com.apple.terminal` / `com.apple.finder`"

DTS 补充："App Review takes a very dim view of folks using temporary exception entitlements"，
并直说需要 script Terminal 的功能"your best option would be to distribute it outside of the Mac App Store"。
→ **精确跳转终端标签页在商店版没有合规路径**，不是"待验证"。

---

## 3. 本机实测（这是本轮新增的证据）

探针源码与产物：`/private/tmp/claude-501/.../scratchpad/sbtest/`（会话临时目录，非仓库内容）。
方法：同一个二进制，分别以 (a) 无沙盒、(b) `com.apple.security.app-sandbox` + `network.client` + `network.server`、
(c) 再加 `temporary-exception.files.home-relative-path.read-write` 及 `temporary-exception.apple-events`（com.apple.Terminal、com.apple.systemevents）三种签名运行，对比行为。

| 行为 | 无沙盒 | 沙盒 | 沙盒 + 文件临时例外 |
|---|---|---|---|
| `FileManager.homeDirectoryForCurrentUser` | `~` | `~/Library/Containers/<id>/Data` | 同左（容器） |
| 列出 `~/.codex/sessions` | 成功 | **拒绝** | 成功 |
| 读 `~/.claude/settings.json` | 成功 | **拒绝** | 成功 |
| 写 `~/.claude/` | 成功 | **拒绝** | 成功 |
| **connect() `~/.codex/app-server-control/app-server-control.sock`** | 成功 | **EPERM** | **仍然 EPERM** |
| bind+listen `127.0.0.1` | 成功 | 成功 | 成功 |
| bind+listen `0.0.0.0` | 成功 | 成功 | 成功 |
| **接受外部非沙盒进程的入站连接并回包** | 成功 | **成功**（收到 168 字节，回 `200 ok`） | 成功 |
| exec `/bin/echo`、`/bin/sh` | 成功 | 成功 | 成功 |
| exec `/usr/bin/python3` | 成功 | 失败 | **失败：`xcrun: error: cannot be used within an App Sandbox.`** |
| exec `/opt/homebrew/bin/python3`、`/opt/homebrew/bin/tmux` | 成功 | **不可见** | **不可见（"The file doesn't exist"）** |
| 子进程读容器外文件 | 成功 | **`Operation not permitted`**（继承沙盒） | — |
| `IOHIDSystem` 空闲时间、`CGSessionCopyCurrentDictionary` | 成功 | 成功 | 成功 |
| `NSWorkspace.runningApplications`、`urlForApplication` | 成功 | 成功 | 成功 |
| `NSAppleScript` → Terminal | 成功 | — | 事件送达（但见下方警告） |

三条最关键的结论：

1. **文件权限 ≠ socket 权限，已实证。** 同一次运行里，`~/.codex/app-server-control/` 目录能列出内容，
   但对同目录下那个 socket 的 `connect()` 依然 `EPERM`。这正好证伪了"给了目录授权 Codex socket 就能用"这个假设。
2. **沙盒 app 可以当服务器，被外部非沙盒进程调用并给出应答。** 这是 hooks 路线的全部技术前提，实测成立。
   意味着 hook 脚本（由 Claude Code / Codex CLI 自己在沙盒外执行）POST 到 `127.0.0.1`，
   商店版 app 收到、弹卡片、等手机回答、再把 `decision` 写回 HTTP 响应——整条阻塞式审批链路在沙盒里是通的。
3. **`Process()` 在沙盒里基本等于废了。** 系统自带二进制能跑但没意义（子进程继承沙盒，读不到任何用户文件），
   用户装的 CLI（Homebrew、npm 全局、`~/.local/bin`）**根本不可见**。所以现有 `ClaudeBackgroundLauncher`、
   各 `*UsageProvider`、`TerminalLauncher/Injector`、`install-*-hooks.py` 在商店版全部不能原样用。

关于 Apple Events 那一行的警告：探针是从 Terminal 启动的，TCC 可能把请求归给了 Terminal 本身，
所以"事件送达"**不能**当作商店版可用的证据；何况规则那一关已经先否掉了（第 2 节）。

---

## 4. 功能矩阵

分三档：**保留**（换接线即可）、**改造**（能力降级但仍有用）、**失去**（商店版没有合规实现）。

### 保留（核心闭环）

| 能力 | 商店版怎么做 | 代价 |
|---|---|---|
| Claude Code 观察（生命周期、statusline、终端捕获） | 现有 hooks 协议不变，脚本从 app bundle 内执行 | 无 |
| **Claude 阻塞式审批 / 问答** | `approval-hook.sh` → `127.0.0.1` → 卡片 → 手机答 → HTTP 响应 | 无（实测通） |
| Codex **CLI** 观察与审批 | `~/.codex/hooks.json` 同一套机制 | 无 |
| 其它 CLI（Grok / Kimi / Qwen / OpenCode / Antigravity）的 hook 观察 | 同上 | 无 |
| 手机 / Watch 配对、消息流、通知去重 | `VibeBuddyServer` 的 HTTP/WS 照旧，`network.server` 已实测可用 | 局域网隐私弹窗（直接版一样有） |
| 通知、Glance、刘海岛、宠物、菜单栏 | 纯 UI，无沙盒问题 | 无 |
| 语音（可选，自带 key，直连提供商） | `device.audio-input` + `network.client` | 无 |
| 登录启动 | `SMAppService` 沙盒可用 | 无 |
| 在场判定（锁屏 / 空闲） | `CGSession*` + `IOHIDSystem` 实测可用 | 无 |
| Codex Desktop 会话的**只读**观察 | 用户授权 `~/.codex/sessions` 后 tail rollout JSONL | 只知道"在等"，不知道等什么 |

### 改造（降级但仍有价值）

| 能力 | 直接版 | 商店版可行做法 |
|---|---|---|
| 安装 / 卸载 hooks | 调 `/usr/bin/env python3` 跑安装脚本 | **必须用 Swift 原生重写**安装逻辑（python3 在沙盒里跑不了）；用 NSOpenPanel 让用户明确选中 `~/.claude` 与 `~/.codex` 配置目录，存 security-scoped bookmark 后直接改文件 |
| 守护进程 token 交换 | 写 `~/Library/Application Support/vibebuddy/token`，hook 脚本读同一路径 | 沙盒下该路径被重定向进容器，**外部脚本能否读取未测**（A1）。安装器注入 VIBEBUDDY_TOKEN_FILE / VIBEBUDDY_PORT / VIBEBUDDY_SUPPORT_DIR；不得把 Claude token 原值写入配置 |
| statusline 包装（保存用户原有命令） | 写 Application Support | 同上，需要改存放位置 |
| 额度 / 用量 | app 直接 spawn `claude` / `codex` / `grok` CLI | app 自己做不到。可行替代：由 hook 脚本（在沙盒外执行）顺带采集并 POST 回来；采不到时显示"未知"而不是假数据 |
| 跳转到终端 | osascript 精确定位 tab / tmux | 只能 `NSWorkspace` 把终端 app 拉到前台，**做不到定位到具体会话的标签页** |
| API key 存储 | 登录 Keychain，两版共用 | **跨版读取未测**（A2）；同 Team 可研究共享 group，但既有条目访问不能由此推定。票 17 先隔离验证，当前不得修改直接版签名/迁移真实凭据 |

### 失去（不要在商店版做假按钮）

| 能力 | 原因 |
|---|---|
| **Codex app-server socket 全部能力** | 沙盒禁止跨团队 Unix socket IPC，临时例外对 socket 无效（Apple 明文） |
| ↳ Codex **Desktop** 的审批 / 问答应答 | 只能靠 socket；rollout 文件只能看出"在等"，答不了 |
| ↳ Codex 实时额度（`account/rateLimits/read`） | 同上，且 fallback 的 `codex app-server --stdio` 要 spawn CLI，也被禁 |
| ↳ 从手机 `POST /dispatch` 新建 / steer Codex 线程 | `thread/start`、`turn/start` 都在 socket 上 |
| **从手机新建 Claude 后台任务** | 要 spawn `claude` 可执行文件，沙盒里不可见 |
| 终端注入 / tmux 控制 | 同上 |
| Cursor 浏览器 cookie 导入 | 需要 spawn 外部进程 |
| Sparkle 自动更新 | 2.4.5(vii) 明文禁止 |

产品目标：**保留观察 / 提醒 / 审批 / 问答主干，尚待真实闭环验收；"从手机主动派活和精确跳转"这一层基本没了。**

---

## 5. 路线建议

**推荐：路线 B（独立沙盒商店版），但把产品定位从"遥控器"收敛为"随身守望 + 远程放行"。**

理由：主干闭环实测可行，而且商店版的用户价值本来就集中在"我在外面，Mac 上的 agent 卡住了，我能看见并放行"，
这部分一个不少。丢掉的是"我在外面凭空派个新任务"和"我回到 Mac 前精确跳到那个 tab"——后者用户本来就在 Mac 前，
拉起终端 app 已经够用。

明确**不建议**路线 C（商店前端 + 另装 bridge）：2.4.5(ii)/(iv) 正面撞车，而且要维护两套安装和版本配对，
把一个"少 30% 功能"的问题换成一个"审核大概率被拒 + 长期维护地狱"的问题。

明确**不建议**路线 D（只读看板）：实测证明审批链路可用，主动降级是白丢核心价值。

**路线 A（直接分发版）必须继续做，且保持完整能力**——Apple 自己在 socket 和 Terminal 两处都建议"这种功能就走直接分发"。
两个版本的定位从此清晰：GitHub 版 = 完整工作站；商店版 = 零门槛安装的守望与放行端。

### 双版本共存的最小改动边界

1. Core/Kit 里所有硬编码 `homeDirectoryForCurrentUser` 的读写，拆成"应用自有存储"（走容器）与"用户授权位置"（走 bookmark）两条。
2. `HookSetup` 从"shell out 到 python3"抽成协议：直接版保留脚本实现，商店版用 Swift 原生实现，两版共用同一份 settings.json 语义与备份/卸载行为。
3. Codex 观察抽成 source：`appserver`（直接版）/ `hooks + rollout`（商店版），UI 按 source 决定能不能给审批按钮——**没有应答通道时不许画审批卡**。
4. 商店版 target 不链接 Sparkle，独立 bundle ID、独立容器、独立默认端口和配对，避免和直接版抢同一个真实请求。

---

## 6. 下一步该做哪个实验

本轮已经把原计划的 P1（Codex socket）和 P2 的技术前提提前跑掉了。剩下最能改变结论的两个：

**实验 1（最高优先）：真实 agent 的端到端 hook 闭环。**
用隔离 bundle ID + 独立端口的沙盒 app，配一份隔离的 Claude 配置，跑一次真实任务，
验证 PermissionRequest 卡片 → 手机批准 → agent 真的执行；再验证 app 退出时 hook fail-open 不卡住 agent。
成功 → 路线 B 落地；失败 → 先定因（token 路径 / 端口 / 脚本可执行位），不要直接降级。

**实验 2：user-selected 授权的真实体验。**
`~/.claude` 和 `~/.codex` 是隐藏目录，NSOpenPanel 选中它们的实际交互是否可接受、
bookmark 重启后是否稳定、用户撤销后能否恢复。这决定 onboarding 能不能做成普通用户能过的流程——
这是商店版存在的唯一理由，如果引导过不去，商店版就没有意义。

审核层面还有一个**未消除的风险**：修改 `~/.claude/settings.json` 属于"改别的 app 的数据"，
2.4.5(i) 要求用"appropriate macOS APIs"，而这里没有官方 API，只有 user-selected 文件授权。
我判断可辩护（用户在 NSOpenPanel 里亲手选中了那个文件），但**这一条只有真提交才能有答案**，
不要在没有审核回执之前说"合规确认"。

---

## 7. 明确未做

- 没有跑通真实 agent 的端到端闭环（实验 1）。
- 没有验证 security-scoped bookmark 的实际 onboarding 与重启恢复（实验 2）。
- 没有做任何商店归档、上传或提交，因此**审核结果完全未知**。
- 没有改动应用代码、hooks、用户代理配置或运行实例。
- ADR-0013 的公众 APNs 依赖与本文无关，也没有因为 Mac 上商店而变化。

## 2026-09-08 Codex 评估更正（不新增实测）

- A1：外部进程读容器 token 和 statusline 原命令备份均未测；票 13 输出布尔结果，不输出 secret。
- A2：Keychain 探针被授权对话框阻塞，既不能推出需重输，也不能推出已有 key 可共享。
- A3：方法已补齐实际 sandbox-exc.entitlements 的文件与 Apple Events 临时例外；未来商店实现禁用全部临时例外。
- A4：/usr/bin/python3 的 xcrun 垫片失败不是所有 Process 的禁令；系统二进制可以执行，子进程继承沙盒，现有外部 CLI 安装器不能原样使用。
- Codex rollout decoder 支持等待事件并不证明 Desktop 实际持久化这些事件；票 15 需真实隔离证据。socket 路线结论不变，Apple 帖末回复明确动态文件授权不包含 socket；帖中对静态临时例外的前后解释有差异，不把早期回复泛化为所有静态例外的定理：[Apple DTS](https://developer.apple.com/forums/thread/788364)。
- 独立原裁决报告未在当前目录定位，未修改该原件；本节纠正当前可接续报告。

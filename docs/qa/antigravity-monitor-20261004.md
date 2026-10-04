# Antigravity monitor：集成与发布验收记录

状态：实现及本轮 Agent 功能验收完成；Mac 1.3.44 (62) 已安装、公开发布且旧版自动升级通过；iOS/Watch 1.3.35 (70) 已提交 Apple，当前等待审核，尚未公开上架。后续实体 Watch 锁屏提醒与触觉补验通过；独立 IDE 已由用户排除。同会话连续提问未再次发送的观察见 AG-05。

## 来源与范围

- 基线 `63145f24140d74cffeb6155f70c0ebd26e0a2992`；集成分支 `codex/antigravity-monitor`。
- [实施规格](../planning/backlog/antigravity-monitor/SPEC.md)、[首版范围](../planning/backlog/antigravity-monitor/PRD.md)。
- [原型结论](../planning/backlog/antigravity-monitor/PROTOTYPE.md)只证明来源可读，不证明产品已接入。
- 一次性源码在 `codex/prototype-antigravity-20261004` 的 `55ad3f97`，不进入生产分支。
- 原型原始证据：`~/Projects/_shared-work/iOS-vibebuddy/antigravity-prototype-20261004/`。

## 环境核实

2026-10-04 检查：`agy 1.2.16`、桌面 Antigravity `2.19.1`。`/Applications` 与 Spotlight 仅发现 Antigravity.app，尚未发现独立 IDE；不能宣称独立 IDE 已验证。
本机有可用 iOS 27 模拟器和配对 Hermes iPhone；设备列表不证明其屏幕可操作、通知已送达或 Watch 可用。随后安装 watchOS 27.0 运行时并创建本任务独立模拟器对；后续分别记录实际验证范围。

## 验收矩阵

| 路径 | 所需证据 | 当前结果 |
| --- | --- | --- |
| 配额 | 官方 JSON → adapter → snapshot → 三端模型组/窗口/reset；失联保留明确过期 | 真实官方 JSON、Mac 与 iPhone 四窗口通过；Watch 卡片显示额度，独立配额页未复验 |
| CLI 自动发现 | 原终端启动，不经 VibeBuddy 托管；新会话及多会话独立 | 原终端新任务自动出现，CLI/Desktop 原生 ID 独立；通过 |
| 桌面自动发现 | 同用户 RPC 列表/步骤 → Session；CLI/桌面来源可辨 | 真实桌面问题等待、回答、完成经隔离 daemon 到手机/Watch；通过 |
| 问题/权限等待 | 原生等待画面与 snapshot 原因一致，无远程控制按钮 | 产品桌面问题、CLI 问题及权限等待通过；桌面权限只核实原生协议，未触发实际等待 |
| 恢复与终止 | 回答后继续，明确完成/失败/取消，工具错误不判失败 | 真实问题恢复、完成、CLI 主动取消通过；工具错误/终止区分有 scoped 检查，未再制造真实执行失败 |
| 观察恢复 | 停止自身观察/重启隔离实例，失联不完成、恢复不重复提醒 | 最终 Mac 包重启恢复已有任务/已读；真实 CLI 断源仍保留等待，恢复同一任务后完成，无伪造 completion；通过 |
| 完整正文 | 实际长结果与 full transcript、手机结果正文逐字对照 | 真实 17,759 字、240 行与 full 日志/HTTP 逐字相等，手机滚至 239 末行；通过 |
| 阅读/提醒 | Mac 原生阅读、iPhone 完整结果、Watch 简短提醒；关注设置和历史不重播 | 三端原生阅读/等待卡片通过；锁屏 APNs/实体触觉未测量，不宣称物理送达通过；本轮收尾决定见末节 |
| 发布 | 独立 Grok Build 评审、PR 合并、版本/签名/公证、发布与可下载产物 | PR #344 已合并；Mac 公证 DMG 已公开、Sparkle 旧版升级通过；iOS 1.3.35 (70) 已提交并等待 Apple 审核 |

## 交付边界

本记录会追加实际命令、源提交、证据路径和未运行项。构建通过、服务快照正确、模拟器画面、真机送达、用户验收分别记录。生产安装前重新核实共享 app 的其他会话/设备使用情况。

## 权限等待来源补证

交互式 CLI 在隔离工作区请求执行 `printf ANTIGRAVITY_PERMISSION_PROBE`，原终端真实展示 Run this command?。一次性批准后输出 `ANTIGRAVITY_PERMISSION_DONE` 并回到空闲，随后 `/exit` 退出。原生 SQLite 步骤从 `(type=132,status=9)` 变成 `(132,3)`，追加最终 planner 行。只读备份、全文和观察记录位于 `~/Projects/_shared-work/iOS-vibebuddy/antigravity-integration-20261004/permission-probe/`。这是当时的来源补证；后续产品 monitor 的真实链路见下文。

`/hooks` 界面确认项目的被动捕获 handler 已加载，但交互式运行未生成捕获文件；需原生数据库承担权威状态，不能用已加载配置冒充 hooks 已交付。

## 隔离原生验收环境

已通过 Xcode 官方 `xcodebuild -downloadPlatform watchOS` 安装 watchOS 27.0 (24R362)，创建独立设备对 VibeBuddy Antigravity Phone QA / Watch QA 并启动；身份见持久证据目录 `antigravity-integration-20261004/simulators.json`。Xcode 27 的原生入口为 Xcode → Open Developer Tool → Device Hub，实际能读取手机模拟器 AX；旧 Simulator.app 名称在此主机不可用。此阶段尚未安装候选；后续候选安装和原生画面证据见下文。

## 集成阶段构建与显示模型

集成源 `3aeb0d94`（含 `0975f4e1` 的来源显示与只读操作提示）完成 Mac unsigned app build 与 iOS simulator build，后者包含 Watch 和 widgets。结果分别在 `.scratch/checks/20261003T201214.187560Z-mac-build/results.json`、`.scratch/checks/20261003T201214.187605Z-ios-build/results.json`。17 项相关 Kit 检查通过，结果在 `.scratch/checks/20261003T200724.605270Z-kit/results.json`。随后桌面状态细化合入 `69b61f45`，不把前述构建证据标作该提交的最终验收。

此阶段候选手机 app 与其内嵌 Watch app 已安装到本任务独立模拟器对，尚未连接产品数据；后续已接入真实隔离服务。其他会话的 Gemini QA app 使用 18769；本任务保留它，后续验收使用独立端口。

桌面真实任务 `b3b65214-18d8-47f5-abf4-9b6399df65ee` 执行合成 printf 后正常返回 `ANTIGRAVITY_DESKTOP_PERMISSION_DONE`，原应用画面与 RPC 一致；命令自动批准，没有出现权限等待，因此不能计入该项通过。步骤证据在持久目录 `antigravity-integration-20261004/desktop-command-steps.json`。

## 真实产品链路（集成源 7f6ab14c）

- 新建桌面合成任务 `06bc0862-9740-4631-b100-956cde3ca60e`，原应用真实停在 Which acceptance path? / Alpha / Beta。隔离 daemon `18789` 的临时 HOME 仅对 Antigravity 来源目录建立读取链接，直接观察运行中的源文件与 RPC，不回放 fixture。doctor 通过。手机显示 Desktop 来源、原问题和回 Mac 处理说明；Watch 显示同一问题与 Desktop。原应用回答 Alpha 后 `/snapshot` 为 done、等待清除，`/completion` 正文精确 `ANTIGRAVITY_DESKTOP_WAIT_DONE`；手机实际正文与已读回执可见。
- 该隔离服务首次后台启动在 exec 父进程退出后消失，doctor 失败；清理自身状态后用持续父进程重新启动并 doctor 通过才驱动。错误启动不算通过。
- 同源 iOS 模拟器构建通过：`.scratch/checks/20261003T202947.424116Z-ios-build/results.json`。
- 已签名候选 `.scratch/deploy/candidate.lnDCjm/VibeBuddyMacApp.app` 构建、签名验证及 Production CloudKit profile 通过。共享安装检查时 `:9876` 无监听、已安装 app 未运行；另一会话运行单独 bundle 的 Gemini QA。未触碰其进程，也未运行会拒绝其他实例的安装脚本。通过原生 UI 启动候选自身路径，占用正常端口；`/Applications` 保持原件。
- 候选 Mac 原生 UI 显示 Antigravity CLI/Desktop 来源；账户页显示四个实际窗口、CLI account 与重置时间。声明 `quotaProviders=antigravity` 的兼容协议请求得到完整四窗口；不声明时旧客户端仍只获原有 provider 集合。
- 新 CLI 合成任务 `8fbad0f3-b3e7-4f6b-9189-b036bfcc60ee` 由原终端直接开启，先问题等待再命令权限等待。手机均自动切换并显示 CLI 来源及原始问题/命令，没有批准按钮；原终端仅一次性批准本任务的 python 打印命令。完整结果已核对：full transcript 与 HTTP 正文均为 17,759 字，short 仅 4,121 字，手机原生滚至 239 末行和结束说明。SHA-256 `bebd4a0e06ca96b0fa9e80764e9035ac46dba2635d0b6ab1c97e1ef8b0f9307d`。
- 持久证据：`antigravity-integration-20261004/live-daemon/` 内的 desktop-waiting / after-answer / completion、cli-question / permission、Mac quota JSON 与手机/Watch 截图。模拟器显示不等同真机推送或触觉验收。

## 评审修正与候选版本

`10dc8a4e`（集成 `bb33f761`）修复等待跨轮 identity、WAL 活跃会话发现、未知结束健康状态与 summary 明确 idle；71 项 scoped tests 通过，两轴只读复核均确认原问题 FIXED。上述 7f6ab14c 运行证据不冒称来自后续修复提交。另修正 Antigravity rail 的不可用创建入口及快捷键；最终候选重新构建。

独立 Grok Build 的 `modelUsage` 确认 `grok-4.7-build-fast`，推理 xhigh。首轮 cancelled 无正式结论；续审正常 end_turn，结论 MERGE WITH FIXES，仅要求提交已存在的创建入口修复。详细记录见 [独立评审](antigravity-review-20261004.md)。

打包阶段版本为 Mac 1.3.44 (62)、iOS/Watch 1.3.35 (70)。当时公开版本为 Mac 1.3.43、iOS 1.3.34；App Store Connect 登录问题随后解决，最终渠道状态见末节。

## 最终候选（源 6c3c98a3）

- Mac 1.3.44 (62) app 与 DMG 均 Apple notarization Accepted、staple/validate 和 Gatekeeper accepted。DMG SHA-256 `43e27c97fb276a897261fe2ccf5ec1a7edfec3861c9ce1783fb0110137ab493f`。
- iOS 1.3.35 (70) archive/export 成功；app、Widget、Watch、通知扩展发行签名，production APNs、Time Sensitive、Watch 版本配对检查通过。IPA SHA-256 `0644f1dcc0304169c2f04c23a5e5bda967134e9dbc1d2ab38a97a8ef4594ee98`。打包不是上架/真机验收。
- 最终 Mac app 从自己的 build 路径运行，原生阅读器显示本任务 full transcript（含 239 末行）；Antigravity rail 无新建按钮，⌘N 不弹出其他 agent 创建窗口。真实模型组配额重新刷新正常。
- 同一真实 CLI 新轮问题等待 → skip → 正常完成，新的 completion `antigravity-cli-6-9` 被接受；随后 `AG_CANCEL_REAL_20261004` 长回答原终端按 Escape，中止被识别为 done / Turn cancelled / failed=false / 无 completionID，不伪造成功正文。证据 `live-daemon/final-build-*.json`。
- 切换自身旧候选时 SIGTERM 后端口已释放但进程未完全退出；保留 `.scratch/antigravity-stop-sample.txt`，仅终止本任务的旧候选和被它阻塞的新进程后重启。此为退出异常记录，不算正常升级重启验收。
- 本轮没有真实 Watch 锁屏、震动与腕上操作证据；这些测量仍为空白。本任务最终采用用户明确要求的 Agent 功能验收，理由及边界见末节。独立 IDE 未安装，不能把桌面验证泛化为独立 IDE。

- 最终候选通过原生 ⌘Q 正常退出，所有候选进程与 9876 监听消失。安装前再次核对 worktree、同项目聊天和进程，无其他 VibeBuddy 实例；事务安装成功，`/Applications/VibeBuddyMacApp.app` 唯一 PID 53393，1.3.44 (62)，独占 9876 且 `/health` 正常。保留旧包于 `/Applications/.VibeBuddyMacApp.app.install.aMuTCF/previous.app`。安装日志 `.scratch/antigravity-install-final.log`。

## 断源恢复补验（最终运行源 6c3c98a3）

真实 CLI 问题 `AG_RECOVERY_20261004` 等待期间，仅临时隐藏隔离 HOME 内由本任务创建的观察链接，未修改原生来源或 agent。快照依次为 healthy → sourceUnreadable（仍为 needsResponse/question、无 completion）→ healthy（同一等待）。在原终端回答 Alpha 后得到 `AG_RECOVERY_DONE`，completion `antigravity-cli-12-16`。证据目录 `antigravity-integration-20261004/source-recovery/` 保留四阶段快照。最初检查脚本预期 temporarilySilent；按实际缺目录语义更正为 sourceUnreadable 后生命周期检查通过，没有更改产品来迎合断言。

## 最终发布及收尾（2026-10-04 05:44，Asia/Shanghai）

- [PR #344](https://github.com/semantic-craft/iOS-vibebuddy/pull/344) 合并提交 `81481451195415f4673ab3291882e8d48b799218`；运行源码为 `6c3c98a3`，后续仅验收文档差异。独立 Grok 结论及修正已在合并前发布于 PR。
- [Mac v1.3.44](https://github.com/semantic-craft/iOS-vibebuddy/releases/tag/v1.3.44) 已公开；下载回读 DMG 的 SHA-256 与上文一致，19,017,654 字节。公开 [Sparkle feed](https://semantic-craft.github.io/iOS-vibebuddy/appcast.xml) 返回 1.3.44 / 62，gh-pages 提交 `e7da5481`。
- Sparkle 实测：先完成共享实例检查并正常退出本任务安装实例，再单独启动 1.3.43 验证副本。原生 Window → 打开菜单栏面板 → 更多 → 检查更新，实际显示 1.3.44 可更新；下载、安装并重启后 About 显示 1.3.44 (62)，health 正常。升级目标为 `.scratch/antigravity-sparkle-old/VibeBuddyMacApp.app`；退出副本后恢复 `/Applications/VibeBuddyMacApp.app`。原始 1.3.43 备份保留，未同时运行两个生产实例。
- iOS 官方 `xcodebuild -exportArchive` 使用已有 Xcode 账户上传，05:34:34 返回 Upload succeeded / EXPORT SUCCEEDED。App Store Connect 已处理并选中 1.3.35 (70)，保存中英更新说明及审核备注，05:44 提交成功。提交 ID `94215e45-b6dd-4322-8ead-744679cd88ac`，页面明确 **等待审核**；保持通过后自动发布。Apple 审批是外部后续状态，不宣称已公开上架。
- 可见提交证据：持久目录 `antigravity-integration-20261004/app-store-waiting-review.jpg`；综合结果 `release-result.json`。本地上传日志 `.scratch/antigravity-ios-upload.log`。所有本任务隔离 daemon、CLI 验收会话和升级验证副本已退出，已安装 Mac 版本继续运行。

## 验收决定与未测量边界

用户在主会话 `01a0f45d-ead5-7121-8f7c-dcc12e61b019` 的直接消息 `01a10382-d567-730d-8ec1-d69d4b5f1a54`、`01a10384-7795-7464-98e1-80d64c819040` 明确要求由 Agent 完成功能验收，不再等待人工签收；`01a10384-c7a3-7224-9e3d-e10e612e158c` 要求 Matt code-review。该决定仅适用本次任务，不改写项目通用验收规则。

两轴补充审阅确认本次 iPhone/Watch 变更为来源标签、配额和既有任务投影，没有改动 APNs、配对或批准传输。真实来源 → adapter → snapshot → 三端原生画面、等待/取消/恢复/完整结果，加上关键回归检查，构成本次功能验收依据。AG-01–AG-04 已完成，按项目惯例删除已完成工单及索引行；产品范围、规格和本记录长期保留。

截至 05:44 未测量（后续变化见末节）：实体手机锁屏 APNs、Watch 触觉/腕上操作；独立 IDE；真实桌面权限等待（已核实协议、桌面问题等待及 CLI 真实权限等待）。实际执行失败未另行制造，工具错误与终止区分由 scoped 检查覆盖。以上不是已通过项，也不要求用户接手本轮验收；Apple 审核结果尚未产生。

## 实体 Watch 补验与范围澄清（后续轮次）

用户明确排除独立 Antigravity IDE，故前文“独立 IDE 未测量”保留为历史事实，不再列为本次验收缺口。用户授权现在进行手表验收，并确认手机联网锁屏、手表佩戴解锁且回到表盘、两端关闭专注模式。已发现 Hermes 的手机版本为 1.3.34 (69)，先构建并安装 1.3.35 (70) Debug 真机包；Watch 最新回传仍为 69，需确认新包已在手表接管后继续。补验原始证据位于 `antigravity-integration-20261004/physical-watch/`。

### 补验结果：锁屏提醒与触觉通过

- 手机安装 1.3.35 (70) Debug；签名 `aps-environment=development`，Mac 现有 APNs `sandbox=true`，未改动凭据或 provider 配置。手表真实回传 `build=70`，且有 `refresh.active.received`，证据 `watch-ready.json`。
- 第一轮 `AGWATCH-70` 于 10:02:53（Asia/Shanghai）APNs accepted；用户当时正在手表应用内，报告没看到提醒，故不计作表盘通知通过。
- 同一 CLI 会话 `9b527596-6e50-497f-818a-1cc5b3e824a4` 回答完成后立即提交 R2，快照显示新问题 `AGWATCH-70-R2`，但最终发送日志中没有该轮新 needs_answer。未查明是快照转换、去重还是其他原因；单列 [AG-05](../planning/backlog/antigravity-monitor/issues/05-repeat-wait-cue.md)，不将重试问题隐藏在本轮通过结论中。
- 改用新真实 CLI 会话 `abd82ed0-4a4c-43ec-a124-7efe88cd5327`，问题 `AGWATCH-70-R3: 手表通知测试`，10:05:12 APNs accepted。用户明确回报在手机锁屏、手表表盘状态下“看到了，也震动了”。这是物理观察证据；Apple 接收记录本身不证明腕上送达。
- 在原 CLI 回答 Continue 后，两会话均 done、waitKind 清空；R3 正文 `AGWATCH_70_R3_DONE`，completion `antigravity-cli-0-3`。两个本任务 CLI 均已 `/exit`，保留真实会话历史。Antigravity 为只读接入，本轮不要求或宣称手表远程批准通过；未补做 Mac 重启后的重复推送及手机重开后的不重播检查。
- 持久证据同前述 `physical-watch/`：`setup.json`、`watch-ready.json`、`r3-waiting-snapshot.json`、`r3-delivery.json`、`watch-after-r3.json`、`resolved-snapshot.json`、`final-delivery.json`、`result.json`。记录已区分第一轮无效条件、R2 待核查和 R3 物理通过。

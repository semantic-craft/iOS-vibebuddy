# Antigravity monitor：集成与发布验收记录

状态：代码已集成，Mac 1.3.44 (62) 已安装且健康；原生三端读取链路通过，真机 Watch 门槛待完成，渠道发布另记。

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
| 观察恢复 | 停止自身观察/重启隔离实例，失联不完成、恢复不重复提醒 | 最终 Mac 包重启恢复已有任务/已读，无新历史 completion；断源恢复未独立驱动 |
| 完整正文 | 实际长结果与 full transcript、手机结果正文逐字对照 | 真实 17,759 字、240 行与 full 日志/HTTP 逐字相等，手机滚至 239 末行；通过 |
| 阅读/提醒 | Mac 原生阅读、iPhone 完整结果、Watch 简短提醒；关注设置和历史不重播 | 三端原生阅读/等待卡片通过；真机锁屏 APNs/触觉尚缺，不宣称通知验收完成 |
| 发布 | 独立 Grok Build 评审、PR 合并、版本/签名/公证、发布与可下载产物 | 独立评审闭环；Mac 公证 DMG、iOS 发行 IPA 完成；渠道发布另记 |

## 交付边界

本记录会追加实际命令、源提交、证据路径和未运行项。构建通过、服务快照正确、模拟器画面、真机送达、用户验收分别记录。生产安装前重新核实共享 app 的其他会话/设备使用情况。

## 权限等待来源补证

交互式 CLI 在隔离工作区请求执行 `printf ANTIGRAVITY_PERMISSION_PROBE`，原终端真实展示 Run this command?。一次性批准后输出 `ANTIGRAVITY_PERMISSION_DONE` 并回到空闲，随后 `/exit` 退出。原生 SQLite 步骤从 `(type=132,status=9)` 变成 `(132,3)`，追加最终 planner 行。只读备份、全文和观察记录位于 `~/Projects/_shared-work/iOS-vibebuddy/antigravity-integration-20261004/permission-probe/`。这是来源补证，产品 monitor 尚未运行。

`/hooks` 界面确认项目的被动捕获 handler 已加载，但交互式运行未生成捕获文件；需原生数据库承担权威状态，不能用已加载配置冒充 hooks 已交付。

## 隔离原生验收环境

已通过 Xcode 官方 `xcodebuild -downloadPlatform watchOS` 安装 watchOS 27.0 (24R362)，创建独立设备对 VibeBuddy Antigravity Phone QA / Watch QA 并启动；身份见持久证据目录 `antigravity-integration-20261004/simulators.json`。Xcode 27 的原生入口为 Xcode → Open Developer Tool → Device Hub，实际能读取手机模拟器 AX；旧 Simulator.app 名称在此主机不可用。尚未安装候选或验证产品画面。

## 集成阶段构建与显示模型

集成源 `3aeb0d94`（含 `0975f4e1` 的来源显示与只读操作提示）完成 Mac unsigned app build 与 iOS simulator build，后者包含 Watch 和 widgets。结果分别在 `.scratch/checks/20261003T201214.187560Z-mac-build/results.json`、`.scratch/checks/20261003T201214.187605Z-ios-build/results.json`。17 项相关 Kit 检查通过，结果在 `.scratch/checks/20261003T200724.605270Z-kit/results.json`。随后桌面状态细化合入 `69b61f45`，不把前述构建证据标作该提交的最终验收。

候选手机 app 与其内嵌 Watch app 已安装到本任务独立模拟器对，尚未连接产品数据。其他会话的 Gemini QA app 使用 18769；本任务保留它，后续验收使用独立端口。

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

待发版本 Mac 1.3.44 (62)、iOS/Watch 1.3.35 (70)。GitHub 最新公开 Mac 为 1.3.43；Apple iTunes lookup 实时返回 iOS 1.3.34（2026-10-02）。App Store Connect 网页当前要求重新登录，尚未核实后台待提交记录。

## 最终候选（源 6c3c98a3）

- Mac 1.3.44 (62) app 与 DMG 均 Apple notarization Accepted、staple/validate 和 Gatekeeper accepted。DMG SHA-256 `43e27c97fb276a897261fe2ccf5ec1a7edfec3861c9ce1783fb0110137ab493f`。
- iOS 1.3.35 (70) archive/export 成功；app、Widget、Watch、通知扩展发行签名，production APNs、Time Sensitive、Watch 版本配对检查通过。IPA SHA-256 `0644f1dcc0304169c2f04c23a5e5bda967134e9dbc1d2ab38a97a8ef4594ee98`。打包不是上架/真机验收。
- 最终 Mac app 从自己的 build 路径运行，原生阅读器显示本任务 full transcript（含 239 末行）；Antigravity rail 无新建按钮，⌘N 不弹出其他 agent 创建窗口。真实模型组配额重新刷新正常。
- 同一真实 CLI 新轮问题等待 → skip → 正常完成，新的 completion `antigravity-cli-6-9` 被接受；随后 `AG_CANCEL_REAL_20261004` 长回答原终端按 Escape，中止被识别为 done / Turn cancelled / failed=false / 无 completionID，不伪造成功正文。证据 `live-daemon/final-build-*.json`。
- 切换自身旧候选时 SIGTERM 后端口已释放但进程未完全退出；保留 `.scratch/antigravity-stop-sample.txt`，仅终止本任务的旧候选和被它阻塞的新进程后重启。此为退出异常记录，不算正常升级重启验收。
- 本轮没有真实 Watch 锁屏、震动与腕上操作证据；依 `docs/watch-notification-acceptance.md` 保留实体门槛。独立 IDE 未安装，不能把桌面验证泛化为独立 IDE。

- 最终候选通过原生 ⌘Q 正常退出，所有候选进程与 9876 监听消失。安装前再次核对 worktree、同项目聊天和进程，无其他 VibeBuddy 实例；事务安装成功，`/Applications/VibeBuddyMacApp.app` 唯一 PID 53393，1.3.44 (62)，独占 9876 且 `/health` 正常。保留旧包于 `/Applications/.VibeBuddyMacApp.app.install.aMuTCF/previous.app`。安装日志 `.scratch/antigravity-install-final.log`。

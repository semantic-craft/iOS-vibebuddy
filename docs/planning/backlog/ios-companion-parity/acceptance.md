# iOS companion parity 实施与验收

日期：2026-10-02。基线：`3b6f481f`（macOS 1.3.40）。分支：`codex/ios-companion-parity`。
按 to-tickets 拆成 6 票，三个实现子代理并行完成第一、二批，主代理集成验证。

## 证据当前位置

2026-10-02 收尾后，本文的 `.scratch/ios-parity/` 和 `.scratch/ios-parity-e2e/`
位于主工作区；仅移动现有证据，未新建备份，原已合并工作树已移除。
iOS 后续正式提交见 [1.3.34 发布记录](../../../qa/grok-ios-1.3.34-distribution.md)。

## 已实现

- IOSP-01：MiniMax 朗读设置、Mac 摘要 / iPhone 声音与凭据归属、密钥草稿保存 / 取消 / 删除、独立朗读语言及旧配置继承、有效风格音色和模型显示。
- IOSP-02：鉴权后的能力探测、按来源和会话读取 Codex 目标；不把 Token 用量当完成进度，不增加控制权限。
- IOSP-03：Codex 分页历史、后台终端只读展示；前台展开时刷新，翻页后保留窗口；旧 Mac 与断开的 Codex 服务使用原本地历史路径。
- IOSP-04：历史 / 离线 / 观测异常提示、配置与已收到信号分开、系统语言入口、诊断文字本地化和无障碍语义。
- IOSP-05：生成 / 播放 / 暂停 / 失败文案，主动系统语音恢复，轮次及来源复核；通话、拔耳机和 VoiceOver 暂停，跳过不擅自恢复。

源、会话、连接代次和游标边界保持独立；历史、目标和终端读取不确认完成，不启动或终止终端。
ADR-0024 已补充手机只读契约。01–05 完成票按仓库规则删除；06 留存设备验收缺口。

## 已验证

| 检查 | 结果 |
| --- | --- |
| `swift test --package-path VibeBuddyKit` | 501 tests / 98 suites 通过 |
| `swift test --package-path VibeBuddyMac` | 1,182 tests / 157 suites 通过 |
| Mac app：XcodeGen + Debug build，关闭签名 | 通过；未安装或启动生产副本 |
| iOS：XcodeGen + build-for-testing | 通过 |
| iPhone 17 Pro 模拟器，iOS 27.0 (24A434) | 177 tests，174 通过、3 条件跳过、0 失败 |
| 带隔离服务的两项 opt-in iOS 网络测试 | 临时签名后 2/2 通过，覆盖实际 URLSession / WebSocket、真实会话与错误令牌拒绝 |
| 中文资源 `plutil -lint`、`git diff --check` | 通过 |

iOS 的第三项跳过检查要求真实 iPhone 麦克风。两个网络检查首次使用未签名包时，HTTP 与鉴权已通过，但设备标识无法落入 Keychain；使用 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 重建后通过。没有修改产品代码来放宽该断言。

隔离服务使用 `127.0.0.1:18841` 和一次性 HOME，通过 verify-vibebuddy doctor。只复制本任务真实 Codex rollout，保留时间戳，不修改原文件。新三种读取未鉴权均返回 401，错误 sourceID 返回 409；断开 app-server 时返回明确 `disconnected`。原 `/history` 成功读取 30 条 / 共 624 条真实消息。

另运行本机 Codex app-server，使用同一一次性 HOME，不复制登录凭据、不新建或执行 turn。目标读取成功返回未设置；原生 history 索引为空，终端返回不可用。该实例没有原线程运行时，不能据此宣称真实目标数值、完整原生历史或活动终端验收通过。

首轮仅确认模拟器中文首页。后续使用仓库原生 XCTest UI harness，已能操作实际应用界面，不再以缺少 `Simulator.app` 作为逐屏验收阻塞。

## 双轴评审

Standards：独立评审发现 Skip 会解除通话后暂停，已修复；保留回归检查，覆盖手动暂停、通话结束和服务商失败三种暂停，最终 iOS 测试通过。复核 PASS。

Spec：评审未参与实现的朗读及任务读取部分，发现终端 15 秒刷新覆盖已加载分页，已修复为保留分页窗口并提供手动刷新；复核 PASS。主代理另核对状态和本地化改动。

## 证据与未验收范围

本地证据位于工作树 `.scratch/ios-parity/`：`kit-final-tests.log`、`mac-final-tests.log`、`mac-app-build.log`、`ios-simulator-tests.log`、`ios-tests.xcresult`、`ios-live-signed-tests.log`、`evidence/`。不提交真实会话正文或临时令牌。

[IOSP-06](issues/06-integration-acceptance.md) 保留：真机 MiniMax 凭据与耳听、真实音频中断 / VoiceOver，以及拥有目标和后台终端的原线程只读展示。未替换生产安装，未发布 App Store / 新 macOS 版本；用户尚未验收。

## 追加：仅本批改动的 E2E 与性能修复

实施提交 `0c50a1e6` 已推送；以下为该提交之后的修复与复验，不重复全仓测试。
隔离 daemon 使用 `127.0.0.1:18842`、一次性 HOME 和本任务真实 Codex rollout；专用 iPhone 17 Pro 模拟器使用临时签名。密钥由带粘贴按钮的原生安全输入框取得，仅注入临时测试进程，不提交凭据或会话正文。

- 真实 MiniMax 四种风格都完成合成、进入 `AVAudioPlayer.isPlaying`、自然结束，未触发系统语音回退。standard / serious / coquettish / sultry 的首段音频时间分别为 1.443 / 0.851 / 0.898 / 1.154 秒（各一次，模拟器观测，不是统计 SLA）。
- 最终音频与真实网络复验 12/12 通过，包括失败请求不切换音频类别、麦克风权限拒绝式接管失败释放所有权、暂停恢复、自然完成不重播、来源一致与历史读取不改变未读状态。最终 standard 首段音频 1.387 秒。
- 修复网络请求开始前抢占音频，以及停止 / 完成时重复释放。一次相同 standard 试听中的同步音频会话 SDK 告警由 6 次降到 3 次；成功播放仍需要同步音频会话操作。主线程轮询最大间隔受模拟器噪声影响，未据此声称卡顿或端到端延迟已降低。
- 独立评审发现通话等待麦克风权限时过早丢弃朗读所有权；已修为保留至实际接管，拒绝或早期失败时释放仍属于朗读的会话，复核 PASS。
- 隔离 HTTP 15 次采样：capabilities p50 0.44 ms / 最大 1.16 ms；goal disconnected p50 0.59 ms / 最大 1.64 ms；真实本地 history p50 28.52 ms / 最大 324.16 ms（包含冷解析）。没有扩大为全应用负载测试。
- 原生 UI E2E 2/2 通过：默认及最大无障碍字号下进入中文朗读设置、选择中文、编辑后取消密钥草稿、确认键盘收起且保存不可用；真实任务显示 Codex 未连接并回退到真实本地历史。截图已核对。范围仅这些操作，未宣称整个旧历史页面已完全汉化，也未做全应用无障碍审计。
- 修复历史页标题遗漏简体中文、取消密钥编辑后键盘未收起，以及大字号下滚动收键盘；键盘状态与草稿状态均有 UI 断言。

新增可重放检查：`VibeBuddyApp/Tests/IOSParityLiveTests.swift`（真实凭据 / 隔离连接通过环境变量显式启用），`tools/a11y-audit/UITests/IOSParityE2E.swift`（隔离连接启用的原生界面检查）。证据保留于 `.scratch/ios-parity-e2e/` 的日志和 xcresult；临时凭据不保留。

## 合并前独立复核

Grok Build `grok-4.7-build-fast` / `xhigh` 对 `3b6f481f..62b5fbd5` 评审提出 6 项应修和 1 项文案问题。`41a72c48` 修复播放恢复失败错误计数、终端过期游标、目标与终端错误恢复、历史回退页重试、原生游标不前进、默认音色随语言更新和删除密钥文案；独立复核七项全部 FIXED，结论 MERGE。

修复后重放：服务端游标 3 项回归通过（旧实现先复现失败）；iOS 音频与真实隔离网络 12/12；原生 UI 两个流程分别通过，新增历史重试和英语→中文默认音色断言。此轮未重复调用付费 MiniMax 合成接口，之前四种风格真实播放证据仍保留。iOS 最终候选为 1.3.33（68）。发布证据见 `docs/qa/release-1.3.41.md`。

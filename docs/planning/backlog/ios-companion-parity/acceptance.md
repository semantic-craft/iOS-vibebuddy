# iOS companion parity 实施与验收

日期：2026-10-02。基线：`3b6f481f`（macOS 1.3.40）。分支：`codex/ios-companion-parity`。
按 to-tickets 拆成 6 票，三个实现子代理并行完成第一、二批，主代理集成验证。

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

应用已在专用模拟器启动，截图确认简体中文首页连上隔离服务并列出真实项目；本机 Xcode 不含 `Simulator.app`，无法通过图形界面继续逐屏点击。截图不是设置页、动态字号或 VoiceOver 验收。

## 双轴评审

Standards：独立评审发现 Skip 会解除通话后暂停，已修复；保留回归检查，覆盖手动暂停、通话结束和服务商失败三种暂停，最终 iOS 测试通过。复核 PASS。

Spec：评审未参与实现的朗读及任务读取部分，发现终端 15 秒刷新覆盖已加载分页，已修复为保留分页窗口并提供手动刷新；复核 PASS。主代理另核对状态和本地化改动。

## 证据与未验收范围

本地证据位于工作树 `.scratch/ios-parity/`：`kit-final-tests.log`、`mac-final-tests.log`、`mac-app-build.log`、`ios-simulator-tests.log`、`ios-tests.xcresult`、`ios-live-signed-tests.log`、`evidence/`。不提交真实会话正文或临时令牌。

[IOSP-06](issues/06-integration-acceptance.md) 保留：逐屏中文 / 大字号 UI，真机 MiniMax 凭据与耳听、真实音频中断 / VoiceOver，以及拥有目标和后台终端的原线程只读展示。未替换生产安装，未发布 App Store / 新 macOS 版本；用户尚未验收。

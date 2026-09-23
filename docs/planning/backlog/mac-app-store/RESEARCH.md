# Mac App Store 可行性研究依据

核查日期：2026-09-06。方法：当前源码 + Apple 官方资料。范围为开发准备；无沙盒 runtime、归档上传或审核证据。

## 确定事项

- 当前工程 `VibeBuddyMacApp/project.yml` 使用 Sparkle，`tools/vibebuddy-mac.entitlements` 明示非沙盒；`tools/release-mac.sh` 面向 Developer ID 公证和 DMG。这证明当前渠道设计，不证明实际安装产物状态。
- Mac App Store 要求沙盒、自包含安装以及商店更新；现有非沙盒与 Sparkle 更新路线不能原样作为商店产物。审核还应检查外部安装依赖与退出后的进程行为。见 [Apple Review Guidelines 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)。
- 麦克风本身是支持的权限，删除语音不是上架前提。见 [Microphone entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone)。具体 key 组合以实际 SDK、沙盒/Hardened Runtime capability 和成品签名为准。
- 沙盒支持用户选定文件和持久 security-scoped bookmark；这不是无条件访问整个 home。見 [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)。文件访问成功不能证明 Unix socket 连接成功。
- 网络收发可通过相应沙盒 entitlement 允许；子进程不会天然逃离父 app 的沙盒边界。见 [Enabling App Sandbox](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)。因此 `Process()` 的存在既不是绝对不合规的证明，也不是能任意驱动 CLI 的证明。
- Apple Events 自动化需考虑目标 app 的 scripting access groups 或特定例外；用户授权并不替代沙盒声明。见 [QA1888](https://developer.apple.com/library/archive/qa/qa1888/_index.html)。公开文档不能预先保证本产品的例外获批。
- macOS 15 起有局域网隐私机制；访问局域网的 app 应解释用途。见 [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。当前 Mac plist 未见局域网用途说明，需在后续实现中核实和补齐；此次不改直接版文件。

## 从源码得出的判断

`CodexAppServerClient.swift` 使用 Unix socket，而不是普通远程 HTTPS API。现有 monitor 已按 ADR-0011 的 amendments 回答审批/问题并创建任务；不能只看 ADR 最初的 read-mostly 描述。商店版是否可复用该连接尚无运行证据。

`HookSetup.swift` 调用 `/usr/bin/env python3`，安装脚本修改外部 agent 配置。这是当前集成方式，尚未证明可被独立的沙盒商店 app 完整承担。候选方向是复用原生 hook 协议，以用户授权配置和最小资源交付打通；安装资源位置、执行权限及 app 自包含性必须验证。

`Presence.swift` 使用锁屏与系统 idle 信息；`TerminalJumper.swift` 和 `TerminalLauncher.swift` 控制终端。不能把这些能力笼统归为“给文件权限就行”，也不应在未检查实际 API 和沙盒行为前统称为必须删掉的辅助功能。

## 结论的强度

当前包不满足两项明确商店要求：有源码和规则依据。核心功能最大保留路线 B：工程假设，待 P1/P2 实验。能否审核通过：未知，不能用静态分析或模型意见保证。

ADR-0013 明确不运营中转服务，同时没有批准把项目 APNs 私钥打包交付公众。该边界来自当前项目决策，不是本次推断。Mac 版进商店不会自动解决公众 iPhone 关闭时推送。

## 补充核查：可执行任务的边界

2026-09-06 再核源码：`hooks/install-claude-hooks.py` 除基础事件还管理 statusline、审批安装与配置备份；MAS-04 必须覆盖这些既有行为，不能用一个简单 curl hook 替换后宣称完成。当前提交为 `717f99d`，本地 main 显示 ahead 1 / behind 19；未合并或同步上游，后续实验重新核对基线。

Apple [QA1888](https://developer.apple.com/library/archive/qa/qa1888/_index.html) 特别指出，向 Finder / System Events 请求 Apple Events 临时例外很可能被拒绝。因此终端跳转票应优先公开 API 与最小目标，不用广泛系统自动化权限作为默认解决方案。该页面为归档资料，实施时结合当前 SDK 与最新审核指南复核。

本轮静态资料仍不能证明 Codex Unix socket 在目标沙盒中可连接。把这一未知转成 MAS-03 的可失败实验，比继续泛泛查询“沙盒能否控制 agent”更有信息价值。尚未运行实验，也未调用 Claude Code 获取外部意见。

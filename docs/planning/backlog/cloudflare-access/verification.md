# Cloudflare Access 验证记录

Date: 2026-10-01

实现已整合到主工作区（整合基线 `22993364`），未提交、推送或发布日常版本。采用 A「原位设置」；VibeBuddy 独立于 Kairos。

## 已验证

- 当前 `swift test --package-path VibeBuddyKit`：499 tests / 97 suites 通过。
- 独立工作区完成 iOS App、Watch、Widget、Notification Service、测试目标编译；当前主工作区完成签名 iPhone QA 和 macOS QA 构建。
- 独立 iPhone `com.vibebuddy.qa.cloudflare`（VibeBuddy CF QA，1.3.31 / 64）已安装到 Hermes；实机查询日常版仍为 1.3.30 / 63，未替换。
- 独立 Mac `com.vibebuddy.e2e.cloudflare-qa` 使用独立状态和非生产端口 18844，原生 UI 显示 Cloudflare 页签与 Access-first 指引。隔离服务读取本聊天真实 Codex rollout 的副本，未修改原始会话。
- 用户完成 Zero Trust Free 激活，并明确授权 QA 凭据、Service Auth 和 Tunnel 配置。已创建：
  - 域名 `vb-qa.xwzhang.com`；Access 应用 `VibeBuddy Cloudflare QA`。
  - 策略 `Hermes QA service token only`，Service Auth，仅包含专用 QA 服务令牌。
  - Tunnel `vibebuddy-cloudflare-qa-helios`；Cloudflare 页面显示正常，cloudflared 收到已发布路由。
- 实际 `CompanionTransport` 经公网 HTTPS 读取真实会话、发送关注操作并回读；WSS 返回相同 sourceID。无 Access、错误 Access Secret、错误 Mac bearer 均被拒绝。
- iPhone QA 内运行生产 `CloudflareConnectionAttempt` / `CompanionTransport` / `ConnectionStore`：从直接连接取得真实 Mac 身份，经公网 WSS 验证后保存凭据，HTTPS/WSS 均成功。
- 重启 iPhone QA，不传配对或 Access 凭据：从持久配置和 Keychain 恢复，经同一 Cloudflare 域名 HTTPS/WSS 连接成功。新增路径检查显示当前为 Wi-Fi（cellular=false、wifi=true）；真机操作回读也通过，尚不能计为蜂窝验收。
- 真实 HTTP 双服务器检查：同域及跨域重定向目标均未收到请求；首次独立 daemon doctor 与真实会话操作通过。
- 独立 Standards / Spec 审阅已完成；Access-first 顺序及重复 bearer 设置问题已修正。`git diff --check` 通过。

## 自动化方法与限制

- iPhone QA 使用临时 XcodeGen spec 和仅存在于 `.scratch/cloudflare-qa/` 的启动驱动，调用生产连接/验证/保存代码。驱动没有加入发布 App，也未编入密钥。
- QA 仅含 App 与测试目标，不携带日常版 iCloud/App Group 权限；不构成通知、Widget、Watch 的验收。通过 `VIBEBUDDY_SKIP_NOTIFICATIONS=1` 启动。
- 首次 XCTest 启动复现 CloudKit 权限 trap：推送回调仍触发 CloudKit 初始化。代码已让 CloudKit 初始化遵守跳过通知开关；后续普通 App 启动和真实网络驱动成功。
- XCTest 修复后两次因 IDE 测试通道断开退出（code 74），断言未执行；不得记为 XCTest 通过。本机无模拟器运行时。
- iPhone Mirroring 连接超时。上述真机证据来自 App 内部调用真实生产逻辑并写出的脱敏结果，尚未验证人工点击表单的界面体验。
- 蜂窝数据及蜂窝下 App 重启已通过（见下文）。连接中断后的自动恢复已通过（见下文）；真实令牌撤销后的新握手拒绝未验收；错误凭据拒绝不能代替撤销验证。
- QA Tunnel 当前由本次运行的 cloudflared 进程维持，未安装开机服务；Mac QA 同样是隔离测试实例，不是日常部署。

## 本地证据

主工作区 `.scratch/cloudflare-qa/`：

- `kit-tests.log`、`ios-build.log`、`ios-live-build.log`、`mac-build.log`。
- `device-tests*.log` / `.xcresult`，保留实际失败结果。
- `live-transport.log`：真实 Cloudflare 两层认证、操作回读与 WSS。
- `phone-seed-result.json`、`phone-restart-result.json`、`phone-network-result.json`：真机检查/保存和无临时凭据重启。
- `access-configured.png`、`tunnel-online.png`：远端配置证据。
- `project.json`、`QACloudflareDriver.swift`、`run-phone-live.py`：可重放的独立 QA 驱动。

凭据文件权限为 0600，实际 iPhone Access 凭据存于其 Keychain；不提交密钥、日志或复制的会话内容。前次独立工作区证据保留在其 `.scratch/cloudflare-*.log` 与 `verify-vibebuddy/cloudflare-local-20261001/`。

## 蜂窝验收接续

用户已确认关闭 iPhone Wi-Fi 和 VPN。随后 devicectl 报设备不可达（CoreDevice 4000/4016），设备列表为 unavailable，当前 USB 枚举未发现 iPhone。无法启动或回读新的手机验收结果，未生成 `phone-cellular-result.json`；旧 Wi-Fi 结果不得替代蜂窝证据。已请用户连接数据线并解锁，保持 Wi-Fi/VPN 关闭。Mac QA 与 cloudflared 进程仍运行。

### 蜂窝实机结果（已通过）

2026-10-01 18:33（Asia/Shanghai），USB 设备状态恢复 connected。用户确认 Wi-Fi 和 VPN 已关闭；App 的 NWPathMonitor 实测 `cellular=true`、`wifi=false`。

- 首次蜂窝运行：18:33:27，HTTPS、WSS、操作回读、Keychain/保存连接均 passed。
- 终止并重启 QA App 后：18:33:41，相同检查全部 passed，仍为蜂窝路径。
- 两次均访问 `https://vb-qa.xwzhang.com`，读取 1 个真实 Codex 会话副本。启动没有提供配对或 Access 凭据，使用已有持久配置和 Keychain。
- 证据：`.scratch/cloudflare-qa/phone-cellular-result.json` 与 `phone-cellular-restart-result.json`。已自动断言蜂窝路径与全部检查结果。

这完成了独立 QA 的真实 Cloudflare + 蜂窝核心通路验收；不代表 XCTest、手动表单 UI、通知扩展、撤销凭据或生产部署已通过。日常 App 未替换。

### 必要补验：Tunnel 中断后的自动重连（已通过）

用户要求只做最必要且有明显收益的测试，因此只补测一次实际通路中断恢复，不扩大边界矩阵或继续排查 XCTest 工具链。

2026-10-01（Asia/Shanghai）：保持 iPhone QA 进程运行，停止本次专用 cloudflared 进程，观察生产 DashboardStore 的状态，而非测试驱动主动重连。

- 18:35:50：connected。
- 18:36:26：failed（已断开——正在重连…）。
- 恢复相同 QA Tunnel 后，18:36:59：自动恢复 connected。
- 中途未重启 iPhone App、未重新输入凭据、未调用 dashboard.start。connected 由生产快照接收路径设置。

证据：`.scratch/cloudflare-qa/phone-recovery-result.json`；自动断言状态顺序为 connected → failed → connected。Tunnel 已恢复运行。按用户收缩后的验证范围，核心通路、认证拒绝、蜂窝、持久化及自动恢复检查完成；真实服务令牌撤销、表单手动 UI 和 XCTest 仍不作已通过声明。日常版本未替换。


## 交付与 QA 清理

作者已授权提交、推送、创建 PR，并删除本次独立 QA App。iPhone 的 `com.vibebuddy.qa.cloudflare` 已卸载，Mac 的独立 QA App 已删除，隔离 Mac 与 cloudflared 进程已停止。日常 App 保留。Cloudflare 专用测试配置保留但 Tunnel 离线，不构成日常部署；脱敏证据保留本地。独立 PR 分支从 origin/main 创建，未包含主工作区其他设置改动或 Web 工作台规划。

仓库要求的独立 Claude Opus 审阅尚未执行：本机无可用 Claude Code 命令。PR 应保持 Draft，直至该合并前审阅完成；此前双轴审阅不能替代此门槛。

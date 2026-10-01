# VibeBuddy 独立 Cloudflare Access 接入 · Spec

Status: ready-for-agent
Date: 2026-10-01

## Problem Statement

iPhone 在外面访问 Mac 的 VibeBuddy，目前依赖局域网或 Tailscale/Headscale 路径。作者希望增加不必开启手机 VPN 的连接方式，保留实时状态与现有操作，而且不依赖 Kairos。只有域名能打开或 HTTPS 能返回内容，不代表 Access 认证、实时连接和操作已经可用。

## Solution

Mac 使用官方 cloudflared，将一个专用域名经 Cloudflare Tunnel 转发到现有 VibeBuddy daemon。Cloudflare Access 使用 Service Auth 策略，仅允许指定设备的 Service Token。iPhone 在已有 Mac 配对基础上填写 HTTPS 地址、Client ID、Client Secret，检查同一台 Mac 的真实快照后保存。

原生 App 每次 HTTP 请求及 WebSocket 握手携带 Access 的两个请求头，同时保留原有 VibeBuddy bearer。用户继续使用现有任务界面，无需 Kairos、WARP、额外 Web 服务或浏览器登录回调。

## User Stories

1. 作为作者，我希望在 iPhone 蜂窝网络上查看 Mac 的真实 Session 状态，以便离开家后继续工作。
2. 作为作者，我希望 Cloudflare 连接不依赖 Kairos，以便单独使用 VibeBuddy。
3. 作为已配对用户，我希望复用 Mac 配对，以便不重新建立另一套账号。
4. 作为用户，我希望输入一个 HTTPS 地址，以便不记忆公网 IP 或远端端口。
5. 作为用户，我希望在原生安全输入框填写设备凭据，以便不通过聊天传递密钥。
6. 作为用户，我希望凭据保存后自动用于连接，以便不在每次查看时登录。
7. 作为用户，我希望检查收到实时快照才显示成功，以便不会把登录页误认为 Mac 服务。
8. 作为用户，我希望检查确认是原先配对的 Mac，以便地址填错时保留原连接。
9. 作为用户，我希望失败、取消或凭据保存失败时保留原连接，以便继续使用现有路径。
10. 作为用户，我希望通过这个入口执行已有的批准、回答或继续操作，以便查看和操作使用同一条有效连接。
11. 作为用户，我希望所有访问 Mac 的请求使用一致的认证，以便不会出现列表能看、操作或注册却失败的情况。
12. 作为用户，我希望普通断线后沿用现有重连逻辑，以便切换网络后恢复。
13. 作为用户，我希望凭据被拒绝时看到可执行的更新提示，以便不被引导去开启 Tailscale。
14. 作为用户，我希望 Mac 离线时如实显示不可达，以便不把旧状态当成当前状态。
15. 作为用户，我希望更换凭据也先验证再保存，以便错误输入不破坏当前连接。
16. 作为用户，我希望切回现有局域网或 Tailscale 方式，以便保留原有使用选择。
17. 作为作者，我希望为设备单独撤销或续期 Access 凭据，以便控制访问范围。
18. 作为现有用户，我希望旧配对仍可读取和使用，以便升级不会要求重新配对。
19. 作为用户，我希望未成功送达的操作仍按现有规则呈现，以便不会误显示已执行。
20. 作为作者，我希望配置指引能明确告诉我怎样验证入口，以便健康页可用不会被误认为完整功能通过。

## Implementation Decisions

- **链路**：iPhone → HTTPS/WSS → Cloudflare Access → Tunnel → 同机现有 HTTP/WS daemon。Mac 新增官方 cloudflared 运行配置及现有连接中心内的轻量配置指引入口；不实现隧道协议，不引入 Worker、数据库或中转 API。
- **入口范围**：第一版单个已配对 Mac、一个 HTTPS origin、标准 443 端口、无子路径。拒绝 HTTP、userinfo、查询参数、fragment 和非根路径；不提供证书校验关闭开关。
- **首次配对**：沿用当前扫码/配对窗口。尚未配对时引导完成现有配对；不支持通过手工输入 Mac bearer 跳过配对。配置前取得并保留已认证的 Mac sourceID，候选快照须匹配；缺少基线时先通过现有路径连接一次。
- **地址契约**：扩展 CompanionEndpoint 和保存的连接配置表达 HTTPS/WSS；旧的无传输字段配对维持 HTTP/WS。只在手机本地保存 Access 凭据引用；不把 Secret 塞进 PairingPayload、二维码、URL、UserDefaults、日志或状态快照。
- **凭据**：使用已有 Keychain 能力，按设备上的连接记录关联并绑定准确 origin；Client ID 与 Client Secret 一起保存。只通过原生输入框输入，不打包共享凭据。初版不自动创建、轮换或续期令牌；用户在 Cloudflare 维护后在 App 更新。
- **认证合成**：Access 使用 CF-Access-Client-Id / CF-Access-Client-Secret；VibeBuddy 仍使用 Authorization bearer。保留两层校验，不用 Access 凭据替换配对 token，不接受只信任代理身份头的新 daemon 通道。
- **请求覆盖**：统一处理快照、WebSocket、操作、历史/内容、设备注册、提醒回执、活动回报及连接同步等所有 phone→Mac 调用；优先扩展已有请求构造入口，必要时只增加一个小的共享构造函数。第三方模型请求不携带这些凭据。
- **重定向**：携带凭据的 Mac 请求不自动跟随重定向，不允许跨 origin 或降级明文转发。登录 HTML、3xx、401/403 不能视为连接成功。凭据缺失或 Keychain 暂不可读时不发送不完整认证请求，不删除配置。
- **保存事务**：编辑为草稿；验证、取消、切后台或配对变更不会提前覆盖旧设置。候选 WebSocket 返回同 sourceID 的快照、凭据持久化成功且草稿仍有效后，才替换连接。失败清理本次临时凭据；凭据更新遵循相同流程。
- **切换路径**：保留一个已验证的直连配置和一个可选 Cloudflare 配置，用户显式切换；不自动探测最优路线、不同时双连、不开发多 Mac 路由器。直连请求永不携带 Access 凭据，旧连接同步提案也不能把 HTTPS/凭据继承给私有 IP。
- **故障表现**：明确区分本地凭据不可用、远程认证被拒绝和网络/源站不可达；证据不足时提示检查 Access 与配对两层认证，不武断称 Mac bearer 错误或令牌一定过期。普通掉线复用重连，认证拒绝避免无限高频重试。
- **操作语义**：复用现有 ControlChannel、等待身份、请求去重及 held decision 规则。更新连接或凭据后重新核对待办仍有效；不得重放已过期审批或把失败写成 accepted。
- **扩展与手表**：保持现有经 iPhone 的操作路径；不把 Secret 同步给 Watch，不新增 Keychain sharing entitlement。实施时核对 Widget/通知实际发起请求的位置，复用当前前台执行约定，不能默默让其中一条路径失效。
- **Mac 界面**：在现有连接中心增加 Cloudflare 说明和配置指引入口，保留扫码配对与已有服务状态；不内嵌 Tunnel 管理器，不把本地服务运行误报为公网连通。端到端成功由 iPhone 收到实时快照确认。
- **Mac 配置**：手工配置一个具名 Tunnel 和自托管 Access 应用，整个专用域名受 Service Auth 保护，策略只包括指定设备令牌。不得使用 Bypass、公开临时隧道或关闭认证实现“能连”。保留 daemon bearer 与现有 LAN 监听，不开放路由器入站端口。
- **ADR 边界**：这扩展 ADR-0025 的单 host/port 配置及私网连接入口；实施首票补充相应决策，明确两种可选路径。不改变 ADR-0009 的 daemon 认证、ADR-0013 的不运营公共中转服务边界，以及 ADR-0032/0033 的操作交付语义。

## Testing Decisions

- 主测试接缝是用户当前的远程连接检查与 SnapshotStreaming / DecisionClient：通过公开 HTTP/WS 行为判断结果，不给每个内部函数建立测试矩阵。
- 复用现有远程连接测试：旧配对可用；候选须收到真实快照；失败或取消不替换；返回其他 sourceID 不保存。只补本次新增失败模式。
- 用少量请求边界测试覆盖 HTTPS/WSS、两个 Access 头与 bearer 同时存在、直连/第三方不带 Access 凭据、拒绝重定向和错误登录响应；Keychain 使用现有可注入操作，验证保存失败保留旧配置。
- 可重放的本地验收使用隔离 daemon、非 9876 端口和一次性 HOME；真实 Claude Code 或 Codex Session 的快照与一种受支持操作须有前后证据。合成事件只能作辅助，不能冒充真实 Agent 验收。
- 本地检查不能证明 Cloudflare 可用。最终须经真实受保护域名，用签名 iPhone 构建关闭 Wi-Fi 和手机 Tailscale/WARP：收到实时 Session 更新、执行一次操作并确认结果、断网恢复、撤销测试设备令牌后拒绝、替换令牌后恢复。Mac 暂离线时显示不可达，恢复后重连。
- 受保护入口缺失 Access 凭据时不得返回快照；Access 正确但 Mac bearer 错误也必须失败。不得输出凭据或二维码到验收记录。
- 验证结果分别记为已修改、自动检查通过、本地端到端通过、真实 Cloudflare/手机通过；缺少任一后两项必须保留具体缺口，不以文档完成或模拟器 UI 代替。
- 已向作者提出上述测试接缝核对；若有补充，以其回复收敛，不默认扩大为全量回归。

## Out of Scope

Kairos 代码、Web 看板、跨项目分类与调度；自建账号/OAuth/浏览器 Cookie 搬运；通用自定义 Header 编辑器；内嵌 Swift TCP 隧道 SDK；自动管理 Cloudflare 账号/DNS/令牌；多主机聚合、自动故障切换、远程唤醒；云端 Agent 执行；改变语音提供商、APNs/CloudKit 或 App Store 分发方案。

## Further Notes

- 收益：少一次手机 VPN 切换，复用现有 Mac 服务及 iPhone 交互，无 Kairos 依赖。
- 代价：域名与 Tunnel 首次配置、Mac 常驻 cloudflared、设备令牌维护，以及经 Cloudflare 的网络延迟；实际蜂窝体验待验收，不承诺所有网络都可达。Mac 休眠时不能执行任务。
- 分四票执行：01 传输与认证 → 02 手机配置；03 Mac 配置入口与指引可与前两票并行准备；04 在 01–03 完成且设备/配置就绪后执行。票据 ready-for-agent 表示规格可实施，不表示外部操作已授权。
- 作者已授权按 A 方案实现；本轮完成本地代码、构建和可用验证，不提交、推送、部署、安装运行版或创建生产凭据。真实域名、Tunnel、设备令牌由实施期使用原生安全配置流程确定，不经聊天收集密钥。
- Mac 安装替换、生产 9876、DNS/Access 修改及上线按仓库授权边界办理；先完成可独立验证的工作，再列出具体配置供作者确认。
- 参考：官方 [cloudflared](https://github.com/cloudflare/cloudflared)、[Service Tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/)、[WebSocket](https://developers.cloudflare.com/network/websockets/)。
- 先例：Immich [已合入的移动请求头支持](https://github.com/immich-app/immich/pull/10588)及[共享 HTTP/WebSocket 网络配置](https://github.com/immich-app/immich/blob/main/mobile/lib/infrastructure/repositories/network.repository.dart)；Swift [Findich](https://github.com/Majorfi/immich-in-finder#servers-behind-an-auth-proxy) 的 Keychain 保存方式。参考行为设计，不直接移植整套网络栈或其 GPL 代码。

- UI 探索：本地两端交互原型，A 原位设置（推荐）、B 分步连接、C 状态优先。作者已于 2026-10-01 确认采用 A「原位设置」；B/C 仅保留为探索参考。原型使用示例数据，不代表 Cloudflare 已接通。


## 最终验收范围（2026-10-01）

作者后续明确要求仅进行最必要且有明显收益的测试。最终完成真实 Cloudflare 的认证拒绝、HTTPS/WSS、真实会话操作回读、蜂窝网络、保存凭据后的重启恢复及 Tunnel 中断后的自动重连；结果见 [验证记录](verification.md)。真实令牌撤销、手动表单 UI、通知/Watch 验收及 XCTest 未计为通过，本轮不再扩展。独立 QA 已获授权清理；提交、推送与创建 PR 已获授权，合并仍由作者决定。

# VibeBuddy 远程连接评估

日期：2026-09-12。范围：离开局域网后，通过 iPhone 和现有 Watch 伴侣查看、回应及操作 Mac 任务。仅评估，未配置隧道或修改应用。

## 结论

**最新交付顺序：用户在研究后决定优先弄 Tailscale。第一阶段为 LAN＋Tailscale，HTTPS／CF 保留到后续阶段。下文 CF 主入口分析是此前方案的研究依据，不再代表当前实施优先级；本地 PRD 已同步。**

按用户最新方向，以 Cloudflare Tunnel + 自备 HTTPS 域名为默认远程入口，Tailscale 保留为高级可选入口；不自动故障切换。研究支持这一产品优先级：手机无需 VPN，现有 HTTP/WebSocket 业务协议可复用。但没有证据表明 CF 在用户实际国内网络比 Tailscale 更快或更稳定，必须实测。两者共享同一套端点配置，不需要重写业务后端。下文早期“自用首选 Tailscale”描述是对最低改造成本的比较，不再代表默认产品顺序；最新判断详见文末。

## 当前代码证据

- `VibeBuddyKit/Sources/VibeBuddyKit/Models.swift` 的 `PairingPayload` 只有 host、port、token、macName，没有传输 scheme。
- `VibeBuddyMacApp/Sources/MenuBarModel.swift` 的 `preparePairing()` 默认选择 `LANAddress.primaryIPv4()`，没有正常产品入口选择 Tailscale 或公网地址。
- `VibeBuddyApp/Sources/SnapshotStream.swift` 写死 `ws://`；`PushRegistration.swift` 和 `DashboardStore.swift` 写死 `http://`。因此 CF HTTPS 地址不是换个 host 就可用，必须统一 HTTP/WebSocket 的端点构造并检查所有动作请求。
- `VibeBuddyApp/Watch/WatchStateStore.swift` 通过 WatchConnectivity 的 `sendMessage` 请求 iPhone 执行动作。给 iPhone 增加远程连接不会自动赋予 Watch 独立蜂窝直连能力。
- `docs/getting-started.md` 明确本地服务没有内置 TLS，并说明 APNs 尚非公共下载版本开箱即用的能力。
- `docs/planning/vision-2026-09.md` Q16 的原决定是 Tailscale 作为进阶选项、不增加云中继。采用 CF 需明确更新这一产品决定及涉及的隐私描述；此次未改写既有决定。

## 方案比较

| 方案与一手来源 | 能解决什么 | 对本项目的判断 |
| --- | --- | --- |
| [tailscale/tailscale](https://github.com/tailscale/tailscale) | Mac 和 iPhone 加入私网，使用稳定私网地址；直接连接失败可走加密中继 | 首选个人自用方案；主要补地址选择、持久化和连接诊断，现有 HTTP/WS 可在加密私网内使用 |
| [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared) | Mac 主动建立隧道，公网 HTTPS 域名转发到本地 HTTP 服务 | 首选免手机 VPN 方案；需 HTTPS/WSS、稳定域名和身份验证集成 |
| [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel) | 将本地服务发布为公网 HTTPS，访问者不必安装 Tailscale | 可作为第三条候选；它是公网入口，不继承私网访问限制。官方仍标 beta，并有域名、端口、带宽限制 |
| [fatedier/frp](https://github.com/fatedier/frp) | 自有公网服务器与 Mac 间建立反向代理，支持 HTTP/HTTPS/TCP | 有节点选址需求时适合；需自己维护公网节点、TLS、入口鉴权和可用性。frpc/frps 的传输 TLS 不等于手机到公网入口的 HTTPS |
| [juanfont/headscale](https://github.com/juanfont/headscale) | 自托管 Tailscale 控制服务 | 想自行掌握控制面时再选；仍需客户端及数据路径设计，不是免 VPN 的 CF 替代品 |
| [tiann/hapi](https://github.com/tiann/hapi) | 包装官方 agent，通过 Web/PWA/Telegram Mini App 远程审批、终端和语音交互 | 业务层相近，可作产品参考或独立替代；不是插入 VibeBuddy 就能保留原生 Mac/iPhone/Watch 行为的网络组件 |

成熟度判断以已有可用产品、发布与文档、目标功能匹配为依据，未进行全面代码审计或供应链审查。HAPI 的能力来自项目自述，不能视为本次实测结果。

## 影响选择的关键事实

1. Tailscale 的直接连接、DERP 和 peer relay 都保持 WireGuard 端到端加密；中继可能影响性能。见 [连接类型](https://tailscale.com/docs/reference/connection-types)。国内蜂窝、公司 Wi-Fi 和实际中继延迟均需实测，不能从项目成熟度推断。
2. 官方指出 iOS 上存在与其他 VPN 的共存限制。若手机日常运行其他 VPN，应优先验证这一点；不能假定关闭全部公网流量接管就能共存。见 [其他 VPN](https://tailscale.com/docs/reference/faq/other-vpns)。
3. CF 可以将公网主机名转发到本地服务，见 [Tunnel](https://developers.cloudflare.com/tunnel/)。其 WebSocket 支持可承载快照流，但边缘更新可能断开长连接，见 [WebSocket 文档](https://developers.cloudflare.com/network/websockets/)。应验收现有重连，不把一次成功连接当成稳定性证明。
4. CF Access 额外鉴权可用 `CF-Access-Client-Id` / `CF-Access-Client-Secret` 请求头，见 [Service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/)。原生客户端必须主动集成，不能假定浏览器登录重定向能被 API/WS 自动处理。若选此方案，凭据按用户设备安全保存，不能在发布包内共享硬编码；与现有应用 bearer 是不同层的凭据。
5. 标准 CF 反向代理在边缘处理 HTTPS，不能把它描述为手机到 Mac、第三方无法读取内容的应用层端到端加密。Tailscale 私网和 Funnel 的加密边界不同；[Funnel 官方说明](https://tailscale.com/docs/features/tailscale-funnel)明确中继不解密，由设备终止 TLS。
6. 远程网络只解决可达性。Mac 必须运行且可达；受原生 agent 控制能力限制的操作不会因此变可用；后台提醒仍需 APNs；Watch 仍需现有 iPhone 桥接条件。

## 推荐实施边界与验收

建议先统一端点模型，支持私网 HTTP/WS 与 HTTPS/WSS；让 Mac 配对入口能选 LAN、Tailscale 地址或自备 HTTPS 地址。不要自研打洞、VPN 或中继服务。先接外置官方客户端，是否内嵌自动安装与生命周期管理另行评估。

若采用公网隧道，仅发布手机所需的路由，排除 `/hook`、`/approval`、`/terminal` 等本机 agent 入口；保留应用鉴权及明确配对窗口。公网入口不能靠隐藏域名充当鉴权。

实施后的验收应覆盖：手机关闭 Wi-Fi 使用蜂窝连接；真实任务快照及已支持动作的回执；Wi-Fi/蜂窝切换后的恢复；响应丢失不自动重复执行动作；鉴权失效；Mac 重启后的重连；Watch 经 iPhone 操作。后台 APNs 和 Watch 独立联网分别记录，不能混同。

本次仅完成代码和一手资料评估，未部署、未替换应用、未做外网真机验收。

## 双入口专项补充与规格依据

用户后续明确要求研究「Tailscale 私网地址＋自备 HTTPS 地址，CF 作为后者首选，复用外置官方客户端」。该范围替代前一轮仅选 Tailscale 的收敛；交付仍为研究和规格，不包含实施。

- **统一位置不仅是快照流。** `VibeBuddyApp/Shared/DecisionClient.swift` 中 snapshot、answer、decision、acknowledge、acknowledge-wait、attention、dispatch、recent-output、jump 都自行构造 HTTP URL。加上 PushRegistration、DashboardStore 和 SnapshotStream，必须共用端点与请求凭据规则，才能覆盖手机、通知动作和经 iPhone 的 Watch 操作。
- **旧客户端会忽略新增 JSON 字段。** 当前 PairingPayload 采用 Codable，旧代码不读取 scheme，仅用 host/port 构造 HTTP。仅添加 `scheme: https` 会导致旧手机尝试明文请求。建议 HTTPS 使用版本化且不含旧顶层 host/port 的二维码，新客户端接受旧 LAN 格式；不能靠新增 version 字段让旧代码自行拒绝。
- **凭据当前不是 Keychain。** `ConnectionStore.swift` 将整个 pairing 存入 UserDefaults。公网端点适配建议一起将配对凭据移入 Keychain；只有安全写入并回读成功后删除旧值。保留现有 pairingEpoch 机制，地址或凭据变化时停止旧连接，拒绝旧 Watch 意图和迟到响应。
- **Tailscale 手工地址是可靠的首版边界。** 官方提供稳定节点 IP 和 MagicDNS；可输入 Tailscale IPv4 或完整 MagicDNS 名，不依赖 Bonjour 跨网发现，也不依赖某个 utun 网卡编号。见 [节点地址](https://tailscale.com/docs/concepts/ip-and-dns-addresses)、[MagicDNS](https://tailscale.com/docs/features/magicdns)。Mac 探测不代表 iPhone 可达；短期无需内嵌 Go/tsnet。
- **HTTPS 首版建议仅支持 origin。** 即 scheme、host、port，路径为空或 `/`；不支持 `/vibebuddy` 这样的路径前缀。CF ingress 匹配路径后不会自动剥离前缀，因此原服务根路由需要重写代理才能接前缀，当前无此必要。CF 提供按 hostname/path 匹配、末尾 catch-all 和 `ingress validate` / `ingress rule` 验证。见 [官方配置文档](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/configuration-file/)。
- **CF Access 与 Tunnel 是独立能力。** 基础 HTTPS 使用现有 bearer 鉴权；另支持用户可选的 Access Service Token。必须配置 Service Auth，并在 HTTP 与 WS 握手均发送两个 CF 请求头，不覆盖应用 Authorization。浏览器交互登录、挑战页面不属于原生客户端自动兼容范围。官方已出现多种 secret 格式，客户端不应硬编码长度或十六进制格式。见 [Service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/)。
- **恢复复用现有机制。** SnapshotStream 的心跳在首帧后启动，DashboardStore 在流结束后两秒重连；需增加有界首次握手和可解释的鉴权／TLS／网络失败，防止握手无帧一直显示连接中。复用 connectionGeneration 与现有动作的 unknown、不重发契约，不能把公网恢复改成命令重试。
- **未验证项。** 没有创建实际 Tunnel、修改 tailnet 或读取凭据；iOS ATS 对实际 Tailscale 地址、DNS 和已发布构建的行为，CF Access WS 组合、Keychain 锁屏读取及真实蜂窝切换必须在实施时验收。未将资料支持的可行性写成已运行成功。

完整规格见本地 tracker：`.scratch/remote-access/PRD.md`。

## CF 主入口专项核实

### 判断与适用条件

结论是支持 CF 主入口，但理由限定为手机使用成本与协议适配。官方发布应用方案把 HTTPS 主机名映射到本地服务；Mac 运行外置 cloudflared，手机不需要 WARP、Tailscale 或 cloudflared。建议连接路径为：iPhone HTTPS/WSS → Cloudflare 边缘 → Tunnel → Mac 回环 HTTP/WS → 现有 Daemon。前述语音直达 provider、Watch 经 iPhone、APNs 独立交付的边界不变。[官方接入指南](https://developers.cloudflare.com/tunnel/get-started/)

**这是手机免配置 VPN，不是整个产品零配置。** 稳定发布需 Cloudflare 账户、接入 Cloudflare 的域名及 Mac connector；域名注册、账户管理、隧道配置与持续运行仍由用户承担。无需为这条路径另租 VPS，但不将其宣传成无条件永久免费或具有某个未经核实的 SLA。若未来要让所有 App Store 用户无需自带域名就一键开通，那是另一项托管服务设计，超出当前研究。[前置条件](https://developers.cloudflare.com/tunnel/get-started/)

### 关键核实结果

| 问题 | 一手依据 | 对我们的含义 |
| --- | --- | --- |
| HTTP 与实时快照能否共用入口？ | [WebSocket 文档](https://developers.cloudflare.com/network/websockets/)说明所有计划支持代理 WS；边缘更新可能断开长连接 | REST 用 HTTPS，快照用 WSS；无需 Worker、Durable Object 或重写消息后端。心跳、首帧超时及重连必须验收 |
| 是否只需 Mac 出站 443？ | [防火墙要求](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)要求 connector 出站 7844，QUIC 使用 UDP，HTTP/2 使用 TCP | 手机访问 HTTPS 与 Mac 建立隧道是两段网络；TCP 回退仍不是 443。不能把“浏览器能上网”当作 Tunnel 可用证据 |
| 能否直接用临时域名作为长期连接？ | [Quick Tunnels](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/)定位开发测试，随机域名，不保证 SLA/在线率 | 默认必须稳定 Tunnel＋域名。不要建立 Worker/KV 来包装临时域名；Quick Tunnel 也不能代替正式路线验收 |
| macOS 如何常驻？ | [macOS 服务文档](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/as-a-service/macos/)区分登录启动 launch agent 与开机启动 launch daemon | 当前菜单栏 Daemon 依赖用户会话，优先采用用户级登录启动说明。Tunnel 启动不能唤醒睡眠 Mac，也不证明应用已运行 |
| 国内是否天然稳定？ | [China Network 官方说明](https://developers.cloudflare.com/china-network/)明确境外路径可能有延迟及可靠性问题，境内网络由独立基础设施提供 | 普通 Tunnel 不等于已获得境内加速。当前无运营商实测证据，不能承诺更快或更稳，也不据此断言一定不可用 |
| WAF 能否替代应用鉴权？ | [WS 文档](https://developers.cloudflare.com/network/websockets/)说明 WAF 检查握手，建立后不继续检查 WS 消息 | 必须保留应用 bearer 和既有动作权限/时效检查；不能因走 CF 就开放手机或 hook 路由 |

### 鉴权与凭据边界

基础 HTTPS 继续使用 VibeBuddy bearer。CF Access 是额外可选层，适合用户需要独立撤销入口凭据的场景；不是使用 Tunnel 必须完成的浏览器登录。若启用，使用 Service Auth policy 和两个固定 Access 请求头，HTTP 请求及 WS 握手均携带；不能复用 Authorization 覆盖应用 bearer。挑战页或身份提供方登录重定向不能当作 JSON API 成功响应。[Service Token 官方契约](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/)

三类凭据必须分开：

- Tunnel token 供 Mac connector 运行远程管理的隧道，不给手机，也不放进配对二维码。Cloudflare 账户 API token 同样不属于手机配置。[Tunnel tokens](https://developers.cloudflare.com/tunnel/reference/tunnel-tokens/)
- Access Service Token 供 iPhone 访问选定 HTTPS 入口，可选、安全输入并存 Keychain。
- VibeBuddy bearer 继续证明应用层配对访问权限；隧道或 Access 认证不替代它。此项来自当前 Pairing 和 ADR-0009 的应用契约。

不能承诺撤销 Access token 会立即切断已经建立的 WS：本次没有取得足以证明这一行为的明确一手契约，也未运行验证。实现验收必须区分“后续握手/HTTP 被拒绝”和“现有快照流是否关闭”；若要即时撤销，应另明确应用会话关闭机制，不从 token 过期自行推断。

### 配置与恢复建议

复用 cloudflared 官方项目即可，无需新增隧道管理库。稳定主机名指向本机回环服务；沿用前述手机路由白名单及 catch-all 拒绝。官方 ingress 支持路径匹配及配置验证，但仅修改本地 YAML 不会自动改变远程管理 Tunnel 的配置：接入说明必须指明采用哪种管理方式，并验证实际生效规则。[配置文档](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/configuration-file/)

以原生 App 的接入结果为准：DNS/网络失败、TLS 失败、Access 拒绝、Daemon bearer 拒绝、源站不可达和首帧超时需保留可判断的状态；没有证据时不要把所有 403 都归因为 Access 或把所有 502 都归因为 Mac 休眠。Cloudflare 的 Healthy 只代表 connector 状态，不能替代完整请求。[排障文档](https://developers.cloudflare.com/tunnel/troubleshooting/)

重连恢复观察，不能自动重发有副作用动作。实际运营商与网络切换试验建议记录首份快照耗时、动作回执耗时、断线恢复时间及失败次数，覆盖常用蜂窝网络、家中出口和公司 Wi-Fi；每项均列原始样本数，不能从单次成功推出可靠率。Tailscale 作为用户手动选择的备用路径，避免未经确认把凭据或待执行命令切换到另一地址。

### 研究交付状态

已核实官方文档并更新本研究记录；没有创建域名/Tunnel、安装软件、读取凭据或完成真实蜂窝验收。本节完成时仅更新研究；后续 to-spec 已根据用户再度选择 Tailscale 优先，将 PRD 调整为两阶段交付。其余双入口共用协议、安全配对和动作不重发约束仍适用。

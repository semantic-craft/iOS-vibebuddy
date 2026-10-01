# Cloudflare Access 连接指引

适用于已支持 Cloudflare 连接设置的 VibeBuddy iPhone 构建。iPhone 通过 HTTPS/WSS 访问专用域名，Mac 上的官方 `cloudflared` 将流量转发给现有 daemon。保留局域网和 Tailscale，不依赖 Kairos，也不需要手机安装 WARP。Mac 必须开机、联网并运行 VibeBuddy；休眠时无法执行任务。

## 三种凭据不要混用

| 凭据 | 用途与位置 |
| --- | --- |
| Access Service Token：Client ID + Client Secret | 授权一台 iPhone 访问专用域名。仅在 iPhone 原生配置表单输入，保存到 Keychain。 |
| Tunnel Token／Tunnel credentials 文件 | 让 Mac 的 cloudflared 接入 Tunnel；不输入 iPhone。本文使用本地管理的具名 Tunnel，其凭据是生成的 JSON 文件，不使用远程管理 Tunnel Token。 |
| VibeBuddy 配对 token（Bearer） | iPhone 原有扫码配对获得，daemon 继续校验。不用 Access token 替换，也不手工复制到 Cloudflare。 |

`cloudflared tunnel login` 生成的账户证书同样留在 Mac。任何真实凭据都不放进聊天、文档、二维码截图、shell 命令参数或日志。本文命令不包含 Secret。Access 的两个头与 VibeBuddy `Authorization` 头同时使用；不要配置 Access 的单 Authorization 头模式。[官方 Service Tokens 文档](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/)

## 开始前确定

- 一个由你管理、DNS 已接入 Cloudflare 的专用域名，例如 `vibebuddy.example.com`，以及所属账户。
- 运行 daemon 的那台 Mac、Tunnel 名称、目标端口和待接入的 iPhone。第一版只接受根 HTTPS 地址与标准 443 端口。
- iPhone 已经通过局域网或 Tailscale 配对并收到这台 Mac 的快照；配置 Cloudflare 前保留这条直连。
- 安装 cloudflared、创建 Tunnel/Access/设备凭据、修改 DNS、安装常驻服务均是实际外部操作。代理执行前需要覆盖这些动作的授权；编写指引或实现 App 不表示已经授权部署。

若要先隔离验收，按 [verify-vibebuddy](agents/skills/verify-vibebuddy/SKILL.md) 使用一次性 HOME 和非 `9876` 端口的 daemon。下面以 `19876` 为例，但须以实际启动端口为准。正式接入现有运行版时才把目标改成 `9876`；不要为配置 Tunnel 再启动第二个生产实例，也不要替换共享安装版 App。

## 1. 先建立 Access 保护

在 Cloudflare One 控制台创建自托管（Self-hosted）应用，域名填完整的专用主机名，路径留空以覆盖全部路径。不要只保护首页或 `/snapshot`，WebSocket 和操作接口也必须经过 Access。[官方应用设置](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)

在 Service credentials → Service Tokens 为这台 iPhone 创建单独令牌，设置可维护的有效期。应用策略选择 **Service Auth**，Include 使用 Service Token 选择刚创建的那一项。不要选 Any Service Token、Everyone、Bypass，或添加会扩大范围的其他策略。先保存保护，再发布 Tunnel 的 DNS 路由。[官方策略说明](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/)

创建时将 Client ID 和 Secret 通过自己的安全凭据管理工具保存，随后在 iPhone 原生表单输入；不要交给聊天收集。不同设备用不同令牌，方便分别撤销。

## 2. 在目标 Mac 建立具名 Tunnel

若未安装，按官方方式安装并通过浏览器登录，选择目标域名所属账户。以下命令实际创建资源，确认部署范围后再执行。[官方本地管理 Tunnel 步骤](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/)

```sh
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create vibebuddy-phone
```

记录生成的 UUID 和 credentials 文件路径，不读取或复制文件内容。新建专用配置 `~/.cloudflared/vibebuddy.yml`；已有其他 Tunnel 配置时不要覆盖它。替换下列 UUID、用户名和域名占位符：

```yaml
tunnel: TUNNEL_UUID
credentials-file: /Users/YOUR_USER/.cloudflared/TUNNEL_UUID.json
ingress:
  - hostname: vibebuddy.example.com
    service: http://127.0.0.1:19876
  - service: http_status:404
```

只转发到同机 daemon，保留末尾 404 兜底规则；不增加其他主机或服务。外部使用 HTTPS/WSS，同机回环到现有 HTTP/WS；不开放路由器入站端口，不修改 daemon 的 LAN 监听和 Bearer 校验。[官方 ingress 配置](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/)

先核对规则，再创建 DNS 路由并前台运行：

```sh
cloudflared tunnel --config ~/.cloudflared/vibebuddy.yml ingress validate
cloudflared tunnel --config ~/.cloudflared/vibebuddy.yml ingress rule https://vibebuddy.example.com/snapshot
cloudflared tunnel route dns vibebuddy-phone vibebuddy.example.com
cloudflared tunnel --config ~/.cloudflared/vibebuddy.yml run vibebuddy-phone
```

预期该域名匹配同机服务，其他域名匹配 404。前台运行按 `Control-C` 停止。Tunnel 显示连接成功只证明 cloudflared 到 Cloudflare 已连通，不能证明手机认证、daemon 或实时任务可用。

## 3. iPhone 检查并保存

1. 在现有 Mac 连接设置中打开 Cloudflare，输入 `https://vibebuddy.example.com`、Client ID 和 Client Secret。不要填路径、Mac 本地端口或 Tunnel Token。
2. 点击“检查并保存”。App 须收到与原配对 Mac 身份一致的实时快照才保存；失败时保留原配置。无需浏览器登录或复制 Cookie。
3. 保存后检查真实 Session；需要时显式切回已保存的直连。App 不自动选择路线。

Mac 连接中心提供说明和配置入口；本地服务状态不代表公网状态。最终以 iPhone 实际结果为准。

## 4. 真实验收

按顺序执行，并记录构建版本、目标环境、结果与时间；不记录凭据、请求头全文、二维码或私有 Session 内容：

1. **缺少 Access 凭据**：不带任何头请求受保护的 `/snapshot`，不应返回快照。下面仅打印状态码，不跟随重定向；重定向或拒绝不能算成功。

   ```sh
   curl --silent --output /dev/null --write-out '%{http_code}\n' https://vibebuddy.example.com/snapshot
   ```

2. **两层凭据正确**：在签名 iPhone 构建里关闭 Wi-Fi、Tailscale 和 WARP，以蜂窝连接。触发真实 Claude Code 或 Codex Session 更新，确认手机持续收到变化；执行一次支持的批准、回答或继续操作，并在 Mac 确认实际结果。只看到健康页或初始缓存不算通过。
3. **Access 正确、Mac Bearer 错误**：在隔离测试实例和测试客户端中使用正确 Access 配置、故意错误的测试配对 token，确认 HTTP 快照和 WebSocket 握手均被拒绝。使用原生安全输入/已有 Keychain 配置注入 Access 凭据，不把真实头写到命令行。不要修改生产 Mac token 或用户已保存配对；没有可用测试客户端时明确记录未验收，不用第一项代替。
4. 断网再恢复，确认实时更新恢复；Mac 暂时离线时显示不可达，恢复后重新连接；不重放已经失效的操作。
5. 撤销专用测试设备令牌，主动断开再重连，确认拒绝；输入新的有效令牌后恢复。不要将“已有 WebSocket 没有立即断开”视为撤销失效，须验证新的握手。轮换正式设备凭据时先验证新值再结束旧值的有效期。

Cloudflare 支持 WebSocket，但网络维护或空闲超时可能断开连接；需要验证 App 心跳和现有重连路径，不能把 HTTP 成功等同于 WSS 成功。[官方 WebSocket 行为](https://developers.cloudflare.com/network/websockets/)

## 常驻、排错与停用

先完成前台运行验收，再选择是否常驻。官方 macOS 方式支持登录时的 `cloudflared service install`（读取 `~/.cloudflared/config.yml`），或开机时的 `sudo cloudflared service install`（读取 `/etc/cloudflared`）。选一种，使用上述已验证配置；先检查已有服务，不能覆盖别的 Tunnel。此步骤需要服务安装授权，不增加自制守护脚本。[官方 macOS 服务指引](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/as-a-service/macos/)

开机服务可按官方指引使用 `sudo launchctl stop com.cloudflare.cloudflared` / `sudo launchctl start com.cloudflare.cloudflared` 重启；登录服务须在同一登录用户会话管理。仅临时 stop 不代表下次登录/开机不会启动。停用本入口时先让手机切回直连、停止这条 Tunnel，再删除专用 DNS 路由；确认入口消失后清理专用 Access 应用和令牌。若该 Tunnel 或服务还承载其他应用，只移除本域名 ingress/路由，不能停掉共享服务。不要先删除 Access 保护而保留可达源站。

| 表现 | 检查位置 |
| --- | --- |
| 登录页、3xx 或 401/403 | 应用域名/路径、Service Auth 与所选令牌、令牌有效期、Mac 配对。仅凭状态码不能断言是哪层凭据失效。 |
| Tunnel 离线 | Mac 唤醒与网络、cloudflared 进程、`cloudflared tunnel info vibebuddy-phone`。 |
| Tunnel 在线但源站不可达 | daemon 是否运行、配置回环地址和端口是否一致；不要为排错启动第二个生产实例。 |
| HTTP 可用但没有持续更新 | 域名 Network 设置中的 WebSockets、握手认证、相关 WAF 规则与 App 重连；不通过 Bypass 解决。 |
| 手机提示凭据不可用 | Keychain 可访问性或重新输入凭据；保留旧配置和直连。 |

本地测试、模拟器检查、真实 Cloudflare 蜂窝验收分别记录。完成指引或看到 Tunnel 在线，不代表最后一项通过。

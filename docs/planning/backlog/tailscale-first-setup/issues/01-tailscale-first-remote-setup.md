# 01: 远程连接以官方 Tailscale 为主路，Surge / Headscale 退为变体

**Status:** done（本 PR）；官方 Tailscale 账号 + 只装 Tailscale 的真机走查未做，见「验收」。

**Blocked by:** None

## 问题

2026-09-26 用 computer use 看了 Mac「设备与连接」和 iPhone「离开家时连接」两页（开发 Mac 上的装机版、iPhone 17 Pro 模拟器 iOS 27），又对照了代码和文档。能力上不依赖 Surge：Mac 从网卡读 `100.64.0.0/10` 地址，任何 Tailscale 客户端（App Store、官网、Homebrew）都能识别；手机只要本机有 tailnet 地址就能「检查并保存」。但呈现让人以为 Surge 或 Headscale 才是主路：

1. iPhone 远程页的网络 App 选择器默认选 Surge（`RemoteConnectionView.swift`），首屏讲的是「在 Surge 里添加 Tailscale 策略，填 Headscale control-url」。
2. Headscale 被当成默认：Mac 未识别到地址时写「把 Tailscale 加入你的 Headscale 网络」并链到 headscale.net；配对卡片写「在 Surge 或 Tailscale 里完成 Headscale 登录」；iPhone 选 Tailscale 后链接仍是 headscale.net。只用官方 Tailscale 的人看不到一条官方指引。
3. iPhone 首次打开远程页时，「网络设置步骤」初始为展开状态，却画成收起的箭头，正文半透明地叠在第 3 节上（`showNetworkSteps = true` 的 `DisclosureGroup` 在 `Form` 里的初始渲染问题），要点两下才正常。
4. `docs/getting-started.md` 的通用 Tailscale 节用了已不存在的界面名称（Use Tailscale for remote access、Pair a phone、Headscale & Surge），还说可以填 MagicDNS 名，而两端界面只接受 `100.x` IPv4。
5. 两端本地化文件里留着一批只讲 Surge / Headscale、代码已不再引用的旧文案。
6. 失败提示「打开 VPN App」固定先试 Surge，两者都装时打不开用户实际用的那个。

## 修法

- iPhone：按已安装的 App 选网络方式（只装 Tailscale → Tailscale；只装 Surge → Surge；都装或都没装 → Tailscale），只在两者都装时显示选择器；用户的选择记下来，失败提示的「打开」按钮优先打开它。
- iPhone Tailscale 步骤：装 Tailscale、用和 Mac 相同的账号登录、保持连接；官方 App Store 链接；Headscale 只留一行"自建服务器"说明和链接。步骤直接展示，不再折叠（顺带去掉初始渲染问题）。第 2 步显示本机是否已有 tailnet 地址（`NetworkInterfaces.hasTailnetAddress`），每次回到前台重查。
- iPhone 地址说明改成"在 Mac 的 Tailscale 里查看 100.x.x.x 地址"。
- Mac：未识别到地址时写"在这台 Mac 上安装并登录 Tailscale，VibeBuddy 会自动找到地址"，给官方下载链接，Headscale 作为次要链接；连接方式副标题、配对卡片提示去掉 Headscale / Surge 默认措辞。
- 失败文案把 Tailscale 放前面（手机、手表一致）。
- 文档：远程一节改为"官方 Tailscale 主路 + Headscale 变体 + iPhone 用 Surge 变体"，只用 `100.x` 地址，写明常开的 Mac 用 Homebrew 版注册成系统服务更稳（开机即连，不需要有人打开 App）。
- 删掉无引用的旧 Surge / Headscale 文案（iOS 20 条、Mac 10 条）。
- 评审第 1 轮后补充：两个 App 都装且没选过时，「打开」按钮照旧先开 Surge（开 Tailscale 会把正在用的 Surge 隧道挤掉），检查成功后记下这次走通的 App；tailnet 地址只认 `utun` 隧道接口（运营商 CGNAT 会给蜂窝网分 100.64/10 地址，之前会误判为已接入）；状态行只在 Tailscale 路径显示（Surge 策略会不会给手机分 100.x 地址没验证过）。

## 验收

- iPhone 17 Pro 模拟器（iOS 27，两个 App 都没装 → Tailscale 路径），英文和简体中文各看一遍：远程页直接是 Tailscale 步骤，没有选择器，也没有重影；手动输入的标签和说明是新文案。状态行显示「已接入 tailnet」，因为模拟器共用开发 Mac 的网卡（那台 Mac 在 tailnet 上）；「尚未接入」分支没有在界面上看到。
- Mac：Debug 构建通过。在开发 Mac 的装机版上看过改动前的「离开 Mac 时」页（地址已就绪分支）；未识别地址分支本机无法触发，由代码审阅确认。
- 没做：两个 App 都装时的选择器和记住选择、失败提示按选择打开 App（模拟器装不了这两个 App）；手机只装官方 Tailscale、用官方账号关 Wi-Fi 走通一遍（需要真机）。

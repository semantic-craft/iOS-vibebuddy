# VibeBuddy 1.3.36 — macOS

- 「设备与连接」的「离开 Mac 时」改为以官方 Tailscale 为主：还没识别到这台 Mac 的 100.x.x.x 地址时，提示直接说「在这台 Mac 上安装并登录 Tailscale，VibeBuddy 会自动找到它的 100.x.x.x 地址」，并给出 Mac 版 Tailscale 的官方下载链接；自建 Headscale 的说明改为次要链接。（Tailscale 的 App Store 版、官网版和 Homebrew 版都可以。）配对卡片和手动填地址的提示也不再默认你在用 Headscale 或 Surge。
- 配套的 iPhone 版（iOS 1.3.30 (63)）同步调整了「在外连接」：按手机上装的 App 显示 Tailscale 或 Surge 的步骤，用 Tailscale 时还会显示这台 iPhone 是否已接入 tailnet。

Mac build 54。配套的 iPhone / Apple Watch 版本为 iOS 1.3.30（63）。

## English

- "Away from Mac" in Devices & connection now leads with official Tailscale: until this Mac's 100.x.x.x address is detected, it says to install and sign in to Tailscale on this Mac — VibeBuddy then finds its 100.x.x.x address on its own — and links to Tailscale's Mac download, with self-hosted Headscale as a secondary link. (Any Tailscale client works: App Store, standalone or Homebrew.) The pairing card and the manual address hint no longer assume Headscale or Surge.
- The matching iPhone update (iOS 1.3.30 (63)) reworks "Connect away from home" the same way: it shows Tailscale or Surge steps depending on what is installed on the phone, and, with Tailscale, whether this iPhone is on a tailnet.

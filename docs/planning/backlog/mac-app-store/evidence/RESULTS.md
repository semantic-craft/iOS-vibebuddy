# 沙盒探针实测记录

日期 2026-09-07。macOS 26.6.2 (25G83)、Xcode 26.6、Swift 6.3.3。仓库 `053a87b`，工作区干净。
探针为独立 bundle ID（`com.vibebuddy.sbprobe*`），Apple Development 证书签名，未触碰任何运行中的 vibebuddy 实例、hooks 或用户代理配置。

复现：`swiftc -O probeN.swift -o probeN`，放进最小 .app bundle，
`codesign --force --sign "Apple Development: …" --entitlements sandbox[-exc].entitlements --options runtime ProbeN.app`，
然后直接执行 `ProbeN.app/Contents/MacOS/probeN`。

## probe.swift — 无沙盒基线 vs 沙盒

无沙盒：
```
INFO  home  ~
PASS  read-codex-sessions        1 entries
PASS  read-claude-settings       17629 bytes
PASS  connect-codex-unix-socket  connected
PASS  listen-0.0.0.0             listening
PASS  spawn-python3              child-ok
PASS  child-read-outside         2026
```

沙盒（app-sandbox + network.client + network.server）：
```
INFO  home  ~/Library/Containers/com.vibebuddy.sbprobe/Data
FAIL  read-codex-sessions        you don't have permission to view it
FAIL  read-claude-settings       you don't have permission to view it
FAIL  connect-codex-unix-socket  connect() errno=1 (Operation not permitted)
PASS  listen-127.0.0.1           listening
PASS  listen-0.0.0.0             listening
FAIL  spawn-python3              env: python3: Operation not permitted
PASS  child-read-outside         ls: …/.codex/sessions: Operation not permitted   ← 子进程继承沙盒
```

## probe2.swift — 加 temporary-exception.files.home-relative-path.read-write

```
PASS  list .codex/sessions               1 entries
PASS  read .claude/settings.json         17629 bytes
PASS  list .codex/app-server-control     3 entries
PASS  write ~/.claude/tmp
FAIL  connect codex.sock                 connect() errno=1 (Operation not permitted)   ← 关键
PASS  exec /bin/echo                     status=0
FAIL  exec /usr/bin/python3              xcrun: error: cannot be used within an App Sandbox.
FAIL  exec /opt/homebrew/bin/python3     The file "python3.14" doesn't exist
FAIL  exec /opt/homebrew/bin/tmux        The file "tmux" doesn't exist
PASS  IOHIDSystem idle / CGSession / NSWorkspace runningApplications
```

**同一次运行里目录可读、socket 仍 EPERM** —— 文件授权不等于 socket 授权，实证。

## probe5.swift — 沙盒 app 作为服务器接受外部连接

```
PASS  bind+listen 127.0.0.1:19901
PASS  accept-inbound-from-unsandboxed   bytes=168
```
外部 `curl -d '{"event":"Stop"}'`（非沙盒进程）收到 `ok`。
→ hook 脚本 → 沙盒 app → 应答，这条链路在沙盒里成立。

## 未测

- security-scoped bookmark 的 onboarding 与重启恢复（需要 GUI app）。
- 真实 agent 的端到端 PermissionRequest 闭环。
- Apple Events：探针从 Terminal 启动，TCC 归因可能落到 Terminal，结果不可信；且规则层面已被 2.4.5 与审核先例否决。
- Keychain 跨版本读取：触发了用户授权对话框导致进程阻塞，未取得干净结论；因此共享或必须重输均未证实；票 17 用隔离虚构条目核验，不读取真实 key。

## 2026-09-08 静态评估更正（无新增探针运行）

- A1：probe1–5 未测沙盒外进程读取容器 token / statusline 原命令备份；留票 13。
- A2：Keychain 无干净结果，不能视为已失败或已共享。
- A3：sandbox-exc.entitlements 同时包含 files.home-relative-path.read-write 与 apple-events（com.apple.Terminal、com.apple.systemevents）；该实验配置不是拟议商店 entitlement。
- A4：/usr/bin/python3 失败包含 xcrun 垫片限制；系统 echo/sh 可执行，子进程继承沙盒，不能概括为 Process 全面禁止。
- probe5 的普通 HTTP 回包不是完整 Hook 审批/问答，更不是 iPhone 到真实 agent 的闭环验收。

# 票 09 实施与自验记录（Claude 接手）

日期：2026-09-08。Owner: Claude（从 Grok Build 接手）。
工作树 `~/Projects/iOS-vibebuddy-wt/mac-app-store`，分支 `feat/mac-app-store-watch-approve`，基线 HEAD 053a87b，**改动未提交**。
隔离 DerivedData：`$SCRATCH/dd-store`（商店）、`$SCRATCH/dd-direct`（直接版）、`$SCRATCH/dd-baseline`（干净基线对照）。
全程未替换 `/Applications/VibeBuddyMacApp.app`，未占用 9876/9877，未修改真实 `~/.claude`、`~/.codex`。

## 接手时的状态

Grok Build 的交付无法编译。修复的问题：

1. `VibeBuddyMacApp/Sources/BuildChannel.swift` 缺 `import VibeBuddyMacCore` → 4 个 `cannot find 'DaemonPort' in scope`。
2. `VibeBuddyMac/Tests/…/DispatchTests.swift` 的 `storeAssemblyAdvertisesNoDispatch` 参数顺序错（`VibeBuddyServer.init` 中 `onDispatch` 在 `claudeLauncher` 之前）→ `swift test` 编译失败。
3. 修好 1 之后暴露的第二层：`MenuBarModel` 是 `@MainActor`，其中用三元表达式在两个闭包字面量之间选择，无法满足 `@Sendable` 上下文类型，编译器报 `converting non-Sendable function value` 与 `failed to produce diagnostic`。改为逐分支 `if/else` 赋值并在字面量上显式写 `@Sendable`（`onAnswer` / `backgroundSessions` / `onAttach` / `onDispatch`，以及 `answer()` 里的 `inject` / `steer` / `startTurn`）。

`VibeBuddyMac/Package.resolved` 的 Sparkle pin：**不是商店改动引入的**。在干净基线 053a87b 的独立 worktree 里跑 xcodegen + 直接版 `xcodebuild` 同样会把它改脏（已实测）。属于「通过 xcodeproj 解析包图会把 Sparkle 写回 Core 包 resolved 文件」的既有现象，与本票无关，不在此处处理。

## AC 逐条结果

| AC | 结果 | 证据 |
|---|---|---|
| 实际 Apple Development 签名含 app-sandbox、网络进出、音频输入、用户选择目录，无 temporary-exception；进程 home 在独立容器 | **PASS** | 见下「签名」「运行」 |
| Daemon 默认 9880 并拒绝 9876/9877；真实 iPhone 扫码 Pairing 成功 | **部分** — 端口全部 PASS，**真机 Pairing 未做** | 见下「端口」 |
| 商店 bundle 无 Sparkle，自更新菜单不出现；直接版隔离构建通过 | **PASS** | 见下「bundle」「直接版」 |
| 首次启动不连 app-server socket、不启动外部 CLI、无未授权目录扫描；无 Dispatch/Attach/终端注入入口 | **PASS** | 见下「启动隔离」 |
| 局域网用途描述存在，记录首次 Pairing 的实际提示结果 | **部分** — 字符串在，弹窗结果待真机 | `NSLocalNetworkUsageDescription` 已在 Info-Store.plist |
| 保留最小 UI、监听、签名与真实 Pairing 证据 | **部分** — 前三项有，Pairing 待真机 | 本文件 |

## 构建与测试

```
cd VibeBuddyMac && swift test
  → 801 tests / 93 suites，2 项失败
cd VibeBuddyKit && swift test
  → EXIT=0，344 tests / 50 suites 全通过
```

两项失败在**干净基线 053a87b 上同样失败**（独立 worktree 实测，798 tests / 92 suites，同样 2 项）：

- `Every supported provider reaches the runtime snapshot`（SessionStoreTests.swift:162，providerQuota 缺 grokBot）
- `/answer cancels the missed timer`（MissedLedgerTests.swift:421/425，202 vs 200）

即**本票未引入回归**。测试数差 +3 / +1 suite 正是新增的 `DaemonPortTests`（3 项）与 dispatch 测试。首轮曾多出 4 项超时类失败（`CompletionResultTests`、`AccountUsageTests`、`CursorBrowserCookieImporterTests`、`GrokUsageProviderTests`），单独重跑 68 tests / 6 suites 全通过，属机器负载导致的时间敏感抖动。

```
xcodebuild -scheme VibeBuddyStore  → ** BUILD SUCCEEDED **
xcodebuild -scheme VibeBuddyMacApp → ** BUILD SUCCEEDED **   # 直接版未受影响
```

## 签名

```
codesign --force --deep --sign "Apple Development: … (B6NUMVUKU7)" \
  --entitlements tools/vibebuddy-store.entitlements --options runtime VibeBuddy.app
codesign --verify --strict  → valid on disk / satisfies its Designated Requirement
codesign -d --entitlements :-
  com.apple.security.app-sandbox                    true
  com.apple.security.device.audio-input             true
  com.apple.security.files.bookmarks.app-scope      true
  com.apple.security.files.user-selected.read-write true
  com.apple.security.network.client                 true
  com.apple.security.network.server                 true
temporary-exception 出现次数：0
Identifier=com.vibebuddy.mac.store   TeamIdentifier=LQAVR62TK2
```

本地 Apple Development 重签 ≠ 正式分发 Archive，票 18 另行验证。

## bundle

```
CFBundleIdentifier      com.vibebuddy.mac.store
CFBundleShortVersionString / CFBundleVersion   1.3.7 / 14
Contents/Frameworks     只有 libswiftCompatibilitySpan.dylib（无 Sparkle.framework）
Info.plist              SUFeedURL 出现次数 0；NSAppleEventsUsageDescription 不存在
                        NSLocalNetworkUsageDescription 存在
Contents/Resources/hooks/  已随包，approval-hook.sh / capture-terminal.sh 保有 rwxr-xr-x
```

`Updater.swift` 由 target 的 `sources.excludes` 排除，菜单里的 Check for Updates 由 `#if !VIBEBUDDY_STORE` 包住。

## 运行（沙盒容器）

```
进程 home = ~/Library/Containers/com.vibebuddy.mac.store/Data
容器内已生成 mac-store.lock / source-id / token
token 权限 rw-------（0600），内容未读取、未输出
```

单实例锁用 `mac-store.lock`，与直接版 `mac-app.lock` 分离。

## 端口

| 启动环境 | 实际监听 | 期望 |
|---|---|---|
| 无 `VIBEBUDDY_PORT` | `*:9880` | ✓ |
| `VIBEBUDDY_PORT=9876` | `*:9880` | ✓ 拒绝覆盖 |
| `VIBEBUDDY_PORT=9877` | `*:9880` | ✓ 拒绝覆盖 |
| `VIBEBUDDY_PORT=9885` | `*:9885` | ✓ 允许普通覆盖 |

全程日常实例仍持有 `*:9876`（pid 96165），未被打断。

## 启动隔离

商店实例启动 10 秒后：

```
持有的 unix socket：无
打开 ~/.codex 或 ~/.claude 下的文件：0 个
子进程：无
TCP 监听：仅 *:9880
已建立的出站连接：无
```

即不连 app-server 控制 socket、不 spawn 任何 CLI、不扫描未授权目录。

## 未完成 / 待真机

- **真实 iPhone 扫码 Pairing 并取得快照**，以及首次局域网提示是否实际弹出、措辞如何。需要 Hermes（17 Pro Max）解锁在手边。此项未做之前票 09 保持 `Progress: in-progress`。
- 正式分发签名与 Archive（票 18）。
- Grok 未写的 `evidence/grok-build/HANDOFF.md` 与 `DESIGN-DECISIONS.md`：本文件取代其中 09 的部分；设计裁定另见 [../triage/TRIAGE-14-15-17.md](../triage/TRIAGE-14-15-17.md)。

## 与主工作区并行 WIP 的重叠

主工作区 `~/Projects/iOS-vibebuddy` 有语音/Watch 的未提交改动（RealtimeAudioIO、VoiceChat、GeminiRealtimeSession、OpenAIRealtimeSession、RealtimeVoice、VoiceCallCoordinator、HalfDuplexGate 删除、ADR-0004 等）。本票改动的文件与之**无交集**，但两者都未合入 main，集成仍未发生。不要把本 worktree 的通过当作主工作区已集成。

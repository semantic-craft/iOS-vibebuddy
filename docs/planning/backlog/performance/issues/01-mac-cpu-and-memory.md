# 01: Mac App 持续高 CPU 与内存体检

**Status:** ready-for-agent

**Blocked by:** None

## 为什么

2026-09-23 06:5x（+0800）实测：`/Applications/VibeBuddyMacApp.app` 1.3.32 已运行 8 小时 27 分，`ps` 连续采样 CPU 22–43%，RSS ≈ 230 MB；当时本机有多个 Claude / Codex 会话在跑。`sample <pid> 3` 显示绝大多数线程在等待（kevent / workq），在 CPU 上的时间分散在 SwiftUI AttributeGraph 更新（`AG::Graph::UpdateStack::update`、`propagate_dirty`）、文件属性扫描（`lstat`、`getattrlist`、`getxattr`）、字符串处理和 JSON 序列化（`JSONWriter.serializeString`）。发布版已剥离符号，无法从这次采样定位到具体函数。先前 1.3.28 的空闲 CPU 根因是 History 重建索引风暴（#245 已修），本票确认是否有新的热点。

## 要做的

- 开发版（带符号），同一台 Mac，三种负载各 10 分钟：无 agent 会话；1 个活跃 Claude 会话；约 5 个活跃会话（Claude + Codex 混合）。每种负载记录 CPU 均值 / p95、内存曲线。
- Instruments Time Profiler 找热点；在快照组装、文件扫描（transcript / rollout / History / Grok 目录）、WebSocket 广播、SwiftUI 刷新入口加 `os_signpost`，记录每分钟次数与耗时。
- 按占比修前 1–3 个热点，例如：去掉重复的文件属性扫描、快照未变化时不广播、界面只在可见数据变化时刷新。
- 连续运行 2 小时看内存是否单调增长。

## 不做

- 不改快照内容和产品行为。
- 不合并 recap ledger 的快照组装（已知约束，见 `SessionStore` 注释与记忆 release-state-2026-09-22-mac-1.3.28）。
- 不替换 `/Applications` 里的共享 App 做测量；开发版与之并行运行（`isolated-mac-app-verification` 的做法）。

## 验收

- [ ] 票据 Comments 里有修复前后同负载的对比数据（命令、时长、均值 / p95）。
- [ ] 空闲 < 2% CPU；约 5 个活跃会话 < 10% CPU（开发版，同一台 Mac）。
- [ ] 2 小时内存无单调增长。
- [ ] `swift test`（Kit、Mac）与 Mac App 构建通过。

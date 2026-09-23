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

## Comments

- 2026-09-23（PR #265，已按 owner 授权装到 `/Applications` 并重启，开发版 Developer ID 签名、未公证）：
  - 主因：History 存档。`SessionHistory/search.sqlite` 29.6 GB（trigram FTS5 覆盖 2.6 GB 文本加一份折叠副本），活跃转录约每 15 s 整体重建索引，每 30 s 全量对账约 4,500 次 SQLite 查询。按 owner 决定删除 History 存档，保留实时会话阅读（只读 `SessionTranscriptReader`）。新版首次启动已删除该目录；空间暂被 13:11 的 Time Machine 本地快照占用，macOS 会自动回收。
  - 其他：快照里的 handoff 扫描（50 个最近目录）缓存 5 s，写交接或 Stop 时失效；3.7 MB `tool-ledger.json` 写入间隔 2 s → 10 s，调用 `facts` 前和 Stop 时强制写盘；账本修剪不再整体复制与深比较。
  - 同一台 Mac、同一时段真实负载（1 个会话 working、其余空闲），`ps` 每 2 s 采样 60 s：
    - 旧版 1.3.32（运行 8.5 h）：CPU 均值 11.2%，峰值 98.9%，RSS 231 MB。更早的一次采样为 22–43%。
    - 新版（启动后 1–2 min）：CPU 均值 3.1%，峰值 18.4%；`footprint` 179 MB（RSS 启动后从 949 MB 回落到约 660 MB，多为可回收的启动期 malloc）。
  - 未完成的验收项：三档负载（无会话 / 1 / 约 5 个活跃会话）各 10 分钟的对比；2 小时内存曲线；空闲 < 2% 的正式测量。本票保持打开，下次按上述三档补测。

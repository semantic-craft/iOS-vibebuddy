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
- 2026-09-23（#265 合并后从 main 9995a12f 重装）：稳定后 CPU 均值 2.7%、峰值 14.8%。新发现：启动后第一分钟 CPU 约 50%（解码几 MB 的回顾账本、工具账本、事件日志），列为本票剩余项之一。
- 2026-09-24（启动第一分钟 CPU，PR #281）：
  - 测法：release 版 `vibebuddyd`（与 App 同一套服务器和 store），非 9876 端口，一次性 HOME（`HOME` 与 `CFFIXED_USER_HOME` 都指向它；只设 `HOME` 时 Foundation 仍用真实家目录）。账本从 `~/Library/Application Support/vibebuddy/` 复制；`~/.claude/projects`、`~/.codex/sessions`、`~/.codex/archived_sessions` 先用 APFS 克隆冻结一份，每次测量再克隆进 HOME，前后两版读同一份输入。`ps -o time` 每 2 s 取累计 CPU 算百分比，启动后 1 / 10 / 30 s 各 `sample <pid> 5`。
  - 根因：启动后第一次 `TokenConsumptionScan`（近 8 天的 Claude 转录与 Codex rollout，约 617 MB + 1.48 GB）逐行 `JSONSerialization` 解析每一行。三次 `sample` 中占满的线程都在这次扫描里：约 45% 在按字节找换行（`Data.firstIndex(of:)`，长行每读 64 KB 就从头再扫一遍），约 21% 在 `ISO8601DateFormatter` 解析时间戳（ICU 每次解析都重新加载日期符号），其余是 JSON 解码。账本解码（`recap-ledger.json`、`tool-ledger.json` 等）在采样里几乎不出现。
  - 修复：换行用 `memchr` 且只搜新读入的字节；解码前先按原始字节过滤，只解析可能计数的行（Claude：含 `"usage"`，或还没拿到 `cwd` 时含 `"cwd"`；Codex：行首已表明是 `response_item` 或无关 `event_msg` 的直接跳过，其余行含所需类型名才解析）；`…Z` 格式的时间戳直接算出 ICU 同样的毫秒值，其他格式仍交给格式化器。在 25.4 万行真实 rollout 上核对：需要解码的数据从 1481 MB 降到 46 MB，应计数的行一行不漏。
  - 同一台 Mac、同一份冻结输入，前后两版背靠背（`ps` 每 2 s，180 s）：
    - 修复前：0–60 s 均值 76.0%、峰值 100%；60–180 s 均值 0.2%、峰值 3.0%；满载约 52 s，共 45.9 CPU 秒。机器繁忙时（load ≈ 20）更长：0–60 s 均值 65.0%，60–180 s 均值 22.4%、峰值 98.5%，满载约 92 s，共 65.9 CPU 秒。
    - 修复后：0–60 s 均值 8.8%、峰值 76%（扫描约 10 s 结束）；60–180 s 均值 0.2%、峰值 2.5%；共 5.6 CPU 秒。
    - 快照里的 token 用量（today / last7Days 的总数、按 agent / 模型 / 项目的各行及其顺序）与修复前逐项相同；`estimatedUSD` 只差浮点求和顺序（约 6e-15，两次修复前的运行之间也是这个量级）。
  - 没有发现无界增长：各账本都有保留期（工具账本 7 天 / 每会话 50 条 / 250 个会话，回顾账本与完成提示 7 天，漏看账本 8 周）。附带观察（未改）：活跃转录每次变化后，5 分钟一次的刷新仍会整份重读（现在很快）；`CursorComposerStore` 在 Cursor 数据库变化时把 1.5 GB 的 `state.vscdb` 复制到临时目录再读（APFS 上是克隆，代价小）。
  - 仍未完成：三档负载 × 10 min、2 h 内存曲线（协调者在全部并行会话合并后统一重装并测）。

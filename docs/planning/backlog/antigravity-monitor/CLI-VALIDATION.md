# CLI 切片验证（2026-10-04）

CLI monitor 自动发现原生 conversation 数据库，全文路径按同一原生 id 读取。
状态使用 native steps + executor termination reason；已完成历史静默导入，
单步 DONE、文件静默、一次工具错误均不制造成功。只读的全局 hooks 使用当前
`~/.gemini/config/hooks.json`，wrapper 补上事件名；原生观察已建立时 hooks 只补充观察信号。

## 已运行

- `swift test --package-path VibeBuddyMac --filter 'Antigravity|HookInstallerTests|CompletionResultTests'`：62 项通过。
  新增 4 项边界回归覆盖 fullyIdle、WAITING→取消→新轮完成与正文、full 优于 short、
  大于 12k 正文与 ledger 持久化。包括实际发现的 WAL 副本读取边界。
- `python3 tools/check.py docs`：通过。
- `verify-vibebuddy` 隔离 daemon，独立 HOME，最终端口 **18779**，doctor 全项通过。
- 回放父任务从真实 agy 1.2.16 权限等待及批准后保存的 SQLite/full 日志：
  HTTP `/snapshot` 显示 permission / needsResponse / controlChannel none / CLI；
  批准后的来源副本变为 done，等待清除，`/completion` 正文严格为
  `ANTIGRAVITY_PERMISSION_DONE`；`/history` 可读 4 条消息。
- 实际执行新版 shell wrapper 向隔离 daemon POST camelCase envelope，stdout 为空且退出 0。
  合成 25,200 字符正文通过 `/completion` 完整返回；这是传输/预算验证，不冒充模型输出。

持久证据：`~/Projects/_shared-work/iOS-vibebuddy/antigravity-integration-20261004/cli-daemon/`
（waiting、after-approval、completion、history、wrapper-long-body 与 helper transcripts）。
真实来源材料在同层 `permission-probe/`。副本回放验证生产 adapter→daemon HTTP 路径，
不等于一次新的原终端实时操作；最终跨端实时任务验收由集成任务继续完成。

## 验证中修正

macOS SQLite 对保留 WAL 模式、但没有 sidecar 的离线文件以 READONLY 打开时可在
prepare 阶段报无法打开文件。按项目已有来源边界复制 main+WAL，确认复制前后 source
revision 未变，再允许 SQLite **仅在私有临时副本**恢复 WAL/SHM；不写原始数据库目录。
每个源文件限制 64 MiB，正文读取限制 32 MiB，未知/不可读来源保持观测不确定。

Antigravity 完整结果独立允许 128 Ki 字符；其他 agent 保持 12k，ledger 总预算仍为
8 MiB。超额明确不可用，不静默截断。手机 CompletionBodyReader 无额外 12k 截断。

一次 QA 中另一会话的 Gemini QA app 同时绑定 localhost:18769，doctor 检出 401；
已仅清理本任务 daemon 并改用 18779，未停止对方 app。该失败不是产品验收证据。

## 待集成验证

- 最终合并代码上的实时 CLI 开始/问题/审批/继续/完成、来源失联恢复与重启不重播。
- Mac/iPhone/Watch 的真实 UI 与通知，以及真实模型生成的 >12k 最终正文。
- 独立 IDE、桌面源和配额由其他切片覆盖。未安装生产应用、未推送、未发版。

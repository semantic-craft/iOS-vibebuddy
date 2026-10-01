# Cursor 本地接入验收：02、07、09

日期：2026-10-01。CLI：`2026.09.28-64d2043`。只在本次工作树修改、构建与验收；未替换运行中的应用、未绑定 9876、未复制凭据。隔离 daemon 的启动、版本切换与最终清理由主代理负责。

## 02：审批失败

修改 `approval-hook.sh`：拒绝非成功 HTTP 与 curl 失败/不完整响应；Cursor 的空响应或服务失败无 stdout、退出 1；其他代理继续退出 0。安装器的 Cursor 审批 deadline 从 30 秒改为 35 秒，容纳 curl 的 30 秒上限。仍仅安装一个 `preToolUse` 审批门。

真实 CLI、临时项目 Hook、实际 shell 写标记的结果：

| 情况 | 结果 | 证据范围 |
| --- | --- | --- |
| 旧脚本空 stdout、exit 0 | 工具执行 | 当前 CLI 将其视为无意见，没有复现意外阻塞 |
| 旧脚本 401 JSON 错误体 | 工具执行 | 旧脚本确实转发错误体，但当前 CLI 此次仍继续 |
| 新脚本空 HTTP 200、401、不可达、30 秒超时 | 工具执行 | 这些探针显式 `--force`；证明 Hook 故障不会额外阻塞 |
| 有效 allow | 工具执行 | 保留批准回复 |
| 有效 deny | 工具不执行，报告 preToolUse blocked | 保留拒绝回复 |
| allow，但 headless CLI 不带 `--force` | 工具不执行 | Hook allow 没有绕过 CLI 自身的写入权限边界 |

`python3 hooks/tests/approval-failures.py` 是可重放的真实 HTTP 回归检查，覆盖空响应、401、截断内容、allow/deny、超时、不可达及 Claude 失败退出码。全部通过。IDE 未在独立 profile 中执行；不能将 CLI 的空输出语义推广到 IDE。ADR-0016 已移除“空 body 就等于 ask”的通用假设，改用官方明确的非 0/2 失败退出契约。

原始本地证据：`.scratch/cursor-local/cli-failures.json`、`cli-baseline401.json`。ACP 单独探针不触发这些项目 Hooks，只验证了 native permission 往返，未拿它充当 CLI Hook 成功证据。

## 07：项目与用户 MCP

使用实际认证的 `agent acp`，与托管 Monitor 相同的 initialize/authenticate/session/new/prompt 字段；`session/new` 保留 `mcpServers: []`。

- 临时项目 `.cursor/mcp.json`：未经批准不会加载；在本次隔离 Cursor 数据目录批准后，真实调用 `vb-project: vb_probe`，同一 toolCallId 的 update 进入 completed，返回 `VB_MCP_OK`。
- 用户 `~/.cursor/mcp.json`：确认原文件不存在后使用 exclusive create，文件仅含本次本地 stdio stub，模式 0600；实际调用 `vb-acceptance-user: vb_probe`，completed、`success: true`，返回 `VB_USER_MCP_OK`。finally 核对内容 SHA-256 完全一致后删除，已确认恢复为不存在。没有覆盖已有配置，也没有读取、复制或修改认证材料。
- 临时 HOME 的项目/用户 MCP 都通过 `agent mcp list` 和 `list-tools` 自动发现；临时 HOME 不继承登录。实际 model 调用使用已有登录 HOME，同时隔离 `CURSOR_CONFIG_DIR` / `CURSOR_DATA_DIR`。这两个变量不能替代用户 MCP 固定的 HOME 路径。

两组真实调用证明空 `mcpServers` 没有禁用本地配置，因此不增加新的 MCP 配置加载器或自动批准开关。代码补充该边界说明。没有改变 session/load 恢复、交叉进程 lease 或单一所有者逻辑。团队 dashboard MCP 仍不在 ACP 支持范围，依据 [Cursor ACP 文档](https://cursor.com/docs/cli/acp)。

项目会话 `5edd8cb3-26d6-460f-b45f-471ac6d0bb6d`；用户会话 `f467f208-1934-401f-8322-5d9045381810`。证据分别为 `.scratch/cursor-local/acp-real.json`、`acp-user-acceptance.json`。这是实际 ACP 与 MCP 协议验收；没有据此声称 Mac/手机原生 UI 验收完成。

## 09：持久任务与只读发现

本机 `agent --help`、`agent persist --help` 明确提供 list / attach / stop。真实流程：

1. 从本次临时目录启动持久 CLI 任务，shell 等待后输出唯一标记；用 Ctrl-B d 断开，`persist list` 同一 UUID 显示 Detached。
2. 一次完整独立任务断开后继续运行、写出 `turn_ended: success`，再 attach；UUID 保持不变。
3. 第二次任务 `f0e5dc2d-defb-4339-867f-9ee05b02065f` 使用临时项目的观察 Hooks 与隔离 daemon 18816；snapshot 从 working 变 done，Hook 与 transcript 两源健康。完成 ID `62B7F258-FEA2-4320-8F38-2364BCD18FD3` 在 reattach 与重启前快照保持一致，未产生新的完成身份。
4. 主代理用新版 binary、新 disposable HOME 重启 18816。没有 Hook 注入，实际 `persist list` 发现同 UUID；snapshot 中 `cursorPersistentDiscovery: available`、`historyOnly: true`、`controlChannel: none`，无 observations 与 completionID。证明只读发现链路不重放旧完成、不冒充实时事件或 ACP 所有权。
5. 仅停止本次创建的两个持久终端；`agent persist list` 回到空清单。所有本次 CLI/ACP 探针已结束；共享隔离 daemon 留给主代理统一清理。

发现器每 30 秒读取官方命令，严格核对原生 UUID、workspace、完整块结构和清单数量；格式不匹配、命令失败、旧版本或缺 tmux 都标 unavailable，保留上次可读结果。终端附着状态只改变历史说明，不能推断 working、等待或完成。新快照字段可被旧客户端忽略；Mac 设置独立显示发现状态，不影响实时接入徽章。

证据：`.scratch/cursor-local/persist-working-snapshot.json`、`persist-detached-snapshot.json`、`persist-discovery-snapshot.json`，以及主代理保存的 `.scratch/verify-vibebuddy/october-integration/cursor-persist-before-restart/snapshot.json`。新 discovery-only daemon sourceID 为 `1A7DF8D4-009D-4E09-985B-D1084CD6D84B`。

## 自动验证与边界

- `swift test --package-path VibeBuddyMac --scratch-path .scratch/build-cursor-local -j 4 --filter 'CursorPersistentSessions|HookInstaller'`：38 项通过。
- `python3 hooks/tests/approval-failures.py`：8 项通过，包含实际 30 秒 HTTP 超时与截断响应。
- `git diff --check`：通过。

新增测试只保留 native 清单解析、历史不创建完成/控制权及实时行去重的关键回归。主代理另外执行整仓验证，结果由主代理记录。本组没有提交或推送，没有删除工单或索引。独立 IDE profile 与原生 Mac/手机像素交互未执行；当前证据分别限定为真实 CLI/ACP、隔离 daemon 快照及自动回归。

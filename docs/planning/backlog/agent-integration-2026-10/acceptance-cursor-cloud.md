# Cursor 云 run SSE 验收（ticket 08）

日期：2026-10-01。范围：活跃 run 实时完成、续连、410 终态恢复、列表发现与轮询兜底。

## 已实现

- v1 `/agents/{id}/runs/{runId}/stream` 使用 `Accept: text/event-stream`，每个当前 run 独立保存 opaque `Last-Event-ID`；更换 run 清除旧 cursor。
- awaited consumer 提供背压，按 byte 解析跨帧 UTF-8/CRLF，单帧/行上限 64 KiB；不累积 assistant/thinking 文本。
- 断线 1→2→4→8→16→20 秒续连。410 停止流重试并读取 Get A Run；列表轮询仍每 20 秒发现、纠偏与重试终态读取。
- SSE `status/result/done` 仅触发权威 run 读取，只有可解码且 run/agent identity 匹配的终态产生 stop；错误、503、仍 RUNNING 均不误完成。
- 每个当前 run 最多一次完成，接受无 ID 的 sticky status 与同 ID 的 result/done。启动 IDLE 仅保留安静历史；换 run、移除 key、停止 monitor 均取消连接。
- daemon 的显式 `VIBEBUDDY_QA_CURSOR_CLOUD_URL` 边界只接受 HTTP loopback、非 9876、`/tmp/vibebuddy-verify-` disposable HOME；使用固定 fixture key，绝不读取或发送真实 Keychain key。

## 检查及可重放证据

目标测试：

```sh
swift test --package-path VibeBuddyMac --scratch-path .scratch/build-cursor-cloud --filter CursorCloud
```

36 项通过，包括跨 byte UTF-8/CRLF/opaque ID、有界超长帧、错误/仍 live 的终态重试、断线续连、410 权威终态、run 替换不泄漏 cursor、key 移除取消连接、新 run 先开始再完成的顺序，以及延迟终态读取期间换 run/移除 key 的取消竞争。现有 cloud API、历史静默与错误/取消终态检查一并通过。

真实 daemon 隔离路径：fake 上游 HTTP/SSE → 生产 `CursorCloudAgentClient` / URLSession bytes → `CursorCloudAgentMonitor` → `SessionStore` → bearer 认证 `/snapshot`。没有 stub `/health` 或 `/snapshot`，没有向 `/hook` 注入替代 completion。

```sh
swift build --package-path VibeBuddyMac --scratch-path .scratch/build-cursor-cloud --product vibebuddyd
python3 tools/qa/cursor-cloud-stream.py \
  .scratch/build-cursor-cloud/out/Products/Debug/vibebuddyd \
  .scratch/verify-vibebuddy/cursor-cloud-final
```

脚本自行选择两个 loopback 空闲端口、创建 disposable HOME，验证 health/认证后运行，最后只终止自身 daemon PID、停止自身 upstream 并清理 disposable HOME。证据目录保留 `daemon.log`、`snapshot.json`、`results.json` 与 `cleanup.json`（请求 path/cursor、轮询采样、延迟、检查项；无真实凭据）。

最终重复运行完成延迟（fake 上游可读取终态 → `/snapshot` 为 done，50ms 采样）：

| 路径 | 实测 |
| --- | ---: |
| SSE 断线后 opaque cursor 续连、终态 frame | 35.2 ms |
| HTTP 410 后读取权威终态 | 687.0 ms |
| SSE 503，20 秒列表轮询兜底 | 17650.4 ms |

SSE 路径在 fixture 中约快 17.6 秒。轮询等待取决于事件落在 20 秒周期的位置；本次特意在周期开始后约 3 秒产生兜底终态。该测量是本机隔离协议路径，不代表真实 Cursor 网络延迟或 APNs 通知耗时。

同一完整路径确认：bc-broken 的终态请求始终 503 后仍 working；bc-history 启动 IDLE 保持 historyOnly 且无 completionID；SSE 重复 result/done、随后列表轮询不新增 completion identity；bc-poll 在流失败后仍完成。

## 真实云边界

未请求或读取真实 API key，未启动付费云任务。本次证明 fake HTTP/SSE 边界下的完整实际 daemon snapshot 路径，不能证明真实 Cursor account 的 SSE 保留期、限流或网络中断行为；真实云、实际设备和 APNs 完成通知未验收。未更换生产 app、未占用 :9876、未修改凭据，未 commit/push。

合同来源：[Cursor 官方 v1 endpoint 文档](https://prod.cursor.com/docs/cloud-agent/api/endpoints)，2026-10-01 阅读；ADR-0018 已撤回暂缓 SSE 的决定并记录现行策略。

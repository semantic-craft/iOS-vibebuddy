# Codex 01 / 03 验收记录（2026-10-01）

实施位置：`language-restart` 隔离工作树。未 commit / push，未启动共享 app-server、未绑定 9876、未替换安装应用或改动凭据。

## 01：生产者认证与独立诊断

从本机已完成的真实 rollout 读取自身 `session_meta`：`originator = Codex Desktop`、`source = vscode`、`cli_version = 0.159.2`。没有用 `codex --version` 替代生产者证据。只将生命周期、工具、usage 和完成记录的结构保留到回放；文本、路径、session/turn/call ID 全部替换。观察到的真实 token 数值用于确认 usage 解码，未保留用户消息或工具内容。

`ObservationHealthDetectorTests.desktop1592Compatibility` 回放得到 prompt → preToolUse → postToolUse → metadata → stop，usage 为 133437 tokens，完整替换结果为 `Verified completion`，完成成功且 turn 不再 active。认证只增加精确版本 0.159.2；同样结构换成未验证的 0.159.3 仍为 unknownVersion。

真实安装 CLI 0.159.2 生成 experimental schema 后：RPC 名称、关键 required fields、InitializeCapabilities 两项能力、六项 opt-out 通知名称全部存在。静态审计 pass，退出码 0；同时共享 socket 不存在被独立输出为 runtimeConnection unavailable、hookTrust unreachable，以及两条 runtimeIssues。静态 pass 不认证连接或 hook 信任。

命令与原始输出：

- `python3 tools/codex-integration/probe.py audit` → `.scratch/codex-static-audit.jsonl`
- `python3 -m py_compile tools/codex-integration/probe.py` → 通过
- 脱敏回放：`.scratch/rollout1592-sanitized.jsonl`；持久回归同样的最小记录在 health 测试内

主 agent 已把该真实脱敏回放置入隔离 daemon 的 disposable HOME，在端口 18816 经正常 rollout 发现取得 HTTP snapshot：`verified1592` 为 done，且具有 completionID。统一端到端记录由主 agent 汇总；这里不声称手机、安装应用或生产共享服务验收。

## 03：有界处理、重同步与选择性重试

保留生命周期、完整 item、usage、审批和 resolution。initialize 只 opt-out 六个确切的未消费 delta 名称，客户端对这些无 id 的通知再过滤；同名 server request 不能被过滤。AsyncStream 最大 256 条，每条及 WebSocket 聚合 payload 最大 1 MiB，payload 缓冲理论上限 256 MiB，实际通常远低于此。

溢出显式设置 requiresResynchronization 并关闭连接。consumer 消化已保留记录后报告 observationOverflow / sourceUnreadable；断线立刻撤销 store 的 progress/control lease，hooks 与 rollout 可接续。重连保留 reducer 及完成/usage 去重，读取曾 active 的实际 turn（最多 4 × 50），合并断线期间漏掉的完整终态。接入中途只有 active status、无 turn ID 时，读取该任务最新持久 turn。找不到或无法读取则持续报告恢复失败，不把它认证为 healthy。审批旧连接的 card 被撤下；重复 request ID 一次 hold / 一次响应。

仅白名单读 RPC 对 -32001 最多三次、短退避加抖动。thread/resume、thread/turn 创建、steer、interrupt 和审批响应不走该重试路径。

高负载测量还复现了 reader Thread 缺少逐帧 autoreleasepool：仅过滤 delta 后 Foundation JSON 临时对象仍会累积。现在每帧释放这些临时对象。

最后焦点运行：

```sh
swift test --package-path VibeBuddyMac --scratch-path .scratch/build-codex-reliability \
  --filter 'CodexReliabilityTests|CodexAppServerReducerTests|ObservationHealthDetectorTests|CodexAppServerApprovalTests'
```

58 tests / 7 suites 通过（`.scratch/reliability-focused.log`）。覆盖重连补回完整结果、审批/完成/usage 去重、断线 fallback、overload 上限和控制写拒绝进入重试。

独立 synthetic burst，避免并行测试干扰堆采样：

```sh
swift test --skip-build --package-path VibeBuddyMac --scratch-path .scratch/build-codex-reliability \
  --filter 'CodexReliabilityTests/boundedBurst'
```

| 相同 10,000 个 1,084-byte delta | 原无界 queue 基线 | 新过滤路径 |
| --- | --- | --- |
| 待消费 wire payload | 10,840,000 bytes | 0 |
| malloc outstanding allocation 增量 | 13,796,800 bytes | 1,584 bytes |
| 本地步骤耗时 | enqueue + drain 10.539 ms | JSON 识别与过滤 33.597 ms |
| 生命周期 queue 另行注入 257 条 | 无界策略无容量信号 | 保留 256 条，显式 overflow |

原始结果：`.scratch/reliability-bench.log`。这里的 memory 是同一进程 malloc outstanding bytes，含 allocator/结构开销，并非 RSS；输入 Data 独立复制，避免共享同一 payload 造成虚假内存节省。耗时步骤工作量不同：基线只排队，新路径还解析 JSON，不能据此声称 CPU 或端到端延迟改善。服务端 opt-out 的实际网络/CPU收益和真实繁忙 app-server 延迟仍待有可订阅共享服务时测量；本轮确认了排队消除、堆临时对象回收及终态恢复正确性。

## 验收边界

- 真实生产者 rollout 回放与隔离 VibeBuddy HTTP snapshot 有证据。
- app-server 协议使用真实安装 schema；恢复/过载/重复审批为 transport 边界回归，未虚构共享服务在线。
- 大于 1 MiB 的消息或超出恢复分页范围会明确中止观测并交给 fallback；没有把截断结果当完整结果。
- Desktop 私有 writer、真实手机、通知投递延迟和生产安装没有在本票中获得新增覆盖。

# 14 — Codex CLI 可从手机放行，其它 CLI 可观察

Status: ready-for-agent
Progress: not-started
Priority: next-cycle-important
Owner: unassigned
Blocked by: 13 关卡：真实 Claude 任务从手机批准、拒绝与回答
Spec: Spec v2（本工作线综合稿）

## What to build

用户按需授权后安装 Codex CLI、Grok、Qwen、Kimi、OpenCode、Antigravity 接入；Codex CLI 的真实审批可从手机放行，其它 CLI 观察生命周期。每种接入都保留用户原有配置并说明重新信任步骤。OpenCode 必须采用 bundle 内资源方案。

## Acceptance criteria

- [ ] 每个已列 CLI 在隔离目录完成安装、重复安装、卸载与用户配置还原；事件及参数遵循对应安装器语义，不将不同宿主 schema 强行统一。
- [ ] Codex 保持同步限时 Hook、PermissionRequest 门和既有审批选择，notify 不变；界面明确要求新会话重新信任，且不读取或伪造信任状态。
- [ ] 真实隔离 Codex CLI 请求经 iPhone 批准后按预期执行；至少另一 CLI 的真实生命周期进入 Daemon 并改变三态。
- [ ] OpenCode 从 bundle 内插件实际加载并将事件送到正确商店端口，正确取得认证且可卸载恢复；不复制插件代码到共享位置，不另装 bridge。
- [ ] 命令形状经未修改直接版的识别方式验证；不因环境注入产生无法识别的重复 Hook，双向完整接管另由 17 验收。
- [ ] Qwen 保留既有 native-http 认证例外但不向日志/截图暴露 query token；token 轮换和端口变化按真实契约处理。
- [ ] 安装成功与宿主确实执行分开记录；Antigravity 等宿主限制如实显示，不把配置存在视为生命周期通过。

## Readiness and verification

转 ready-for-agent 前需明确可行的 OpenCode bundle 引用与认证输入，以及 Codex 命令识别方案；这些未测，不得删除 CLI 范围或暗改直接版解除阻塞。保持同一票拥有完整配置到事件验收，避免单独建无产品结果的“移植层”票。

验证采用隔离实际应用和真实代理的用户结果；复用已有 Server、存储、安装器与 Keychain 注入边界。实现时运行两个共享包的必要测试；构建、模拟/fixture 与真实手机验收分别留证，不为拆票增加无关抽象。

## 执行边界

本轮为 to-tickets 整理，未授权开始第二阶段。实施确认后只领取所有 Blocked by 已完成的票，领取写 Owner，全部验收具备证据后才写 Progress: completed。全部工作使用隔离商店 target 和配置；直接版构建、签名、Sparkle、行为不变，不替换日常应用，不占 9876/9877，不改真实代理配置或凭据，不新增临时例外、第二安装包或 bridge，不提交/推送/同步/发布。日志和票不含 token、key 或用户目录内容。具体源码定位、命令与执行证据留在实施方案和验收记录中。

## Comments

- 2026-09-08：由 SPEC-store-v1 拆出，取代 02–08 候选票。

- 2026-09-08 Codex 第一阶段静态评估（未领取、未实施）：实际 Codex marker 严格匹配 argv，不能声称环境前缀后 Python 无需改就能接管。OpenCode 安装器复制 JS 到用户插件目录，且 JS 不读取 TOKEN_FILE；改为先核实 bundle 引用机制，不把复制代码方案视为可实施。Qwen query-token 为 ADR-0009 的既有特例，不能把配置输出进证据。 详见修订后的 IMPLEMENTATION-PLAN.html 票 14；实现与验收仍未执行。

- 2026-09-08 to-tickets：依据 Spec v2 重写为可验证的用户行为切片，保留编号、历史 Comments 和未领取状态；当前正文替代此前分歧建议，具体实现方法仍需实际验证。Status 调整为 needs-triage；不代表已确认实施。

- 2026-09-08 Claude triage（未领取实施）：两个未知均已实测解决，详见 [evidence/triage/TRIAGE-14-15-17.md](../evidence/triage/TRIAGE-14-15-17.md)。
  OpenCode：`opencode.json` 的 `plugin` 数组接受绝对路径，opencode 1.17.14 规范化为 `file://` 并实际求值 bundle 内模块（`plugin_origins` + 工厂调用标记为证）；插件用 `import.meta.url` 定位自身、读同目录静态 `endpoint.json`、再读商店容器的 `port`/`token`，实测解析出 9880 与 fixture token。无任何可执行代码离开 bundle，无需第二安装包或 bridge。
  Codex：环境前缀是死路——未修改的 `install-codex-hooks.py` 的 `is_forwarder` 要求 `shlex.split` 后恰好 2 个 token，`VIBEBUDDY_PORT=… "…forward.sh" codex` 判为 False。改用 bundle 内同名脚本的绝对路径（无 env 前缀）后判为 True，`approval-hook.sh` / `capture-terminal.sh` 同理。真实隔离 codex-cli 0.153.4 执行该 hook，SessionStart 与 Stop 均带 Bearer 到达商店端口监听器。商店变体脚本自行从容器读 `port`/`token`。
  其它 CLI：只有 Codex 是严格 argv 匹配；Claude / Grok / Qwen / Kimi / Antigravity 都是子串 marker，bundle 路径同样识别。
  新增依赖：票 11 的目录授权范围需扩到 `~/.config/opencode` 及其它已列 CLI 的配置目录，当前票 11 只写了 Claude 与 Codex。
  仍受 13 关卡阻塞；本条只解除 triage，不代表已实施或已验收。

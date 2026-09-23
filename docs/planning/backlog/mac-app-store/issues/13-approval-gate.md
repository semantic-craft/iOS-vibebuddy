# 13 — 关卡：真实 Claude 任务从手机批准、拒绝与回答

Status: ready-for-agent
Progress: not-started
Priority: next-cycle-important
Owner: unassigned
Blocked by: 12 从 Settings 安装 Claude Hook 并收到真实事件
Spec: Spec v2（本工作线综合稿）

## What to build

用户在 iPhone 对真实 Claude 请求批准、拒绝或回答后，代理按决定执行；Mac 先回答会撤下手机卡片；商店版退出时代理回到自身提示。此票是产品关卡，通过前 14–18 一律不领票，失败先定因，不削减产品范围。

## Acceptance criteria

- [ ] 外部进程读取商店容器 token 与原 Status line 备份的 A1 结果有独立证据；只记录读取成功/非空/权限及真实认证结果，不输出内容或将非 401 当成功。
- [ ] 真实 iPhone 与隔离商店实例配对，批准、拒绝、AskUserQuestion 回答各一次往返；隔离动作的实际后果与决定一致，不以卡片或 HTTP 回包代替执行证据。
- [ ] Presence 为 away 或显式 phone-first 时远程放行成立；本地 Presence 的 read-only card 路径单独验证，不与远程放行混淆。
- [ ] Mac 卡片先答后手机撤卡，重复/晚到响应不会二次执行同一请求。
- [ ] 应用退出后再触发审批，Claude 返回自身提示；连接拒绝与无回答的有界等待分别记录，不能永久卡死，也不将所有故障承诺为一秒。
- [ ] Status line sample 填充既有 Session 名称和上下文，Live usage feed 收到可用样本；无凭空新建 Session。
- [ ] 记录脱敏命令、结果、时间及截图定位，全部使用隔离配置，未修改真实代理配置或运行中的直接版。

## Readiness and verification

若 token 读取、脚本执行、版本或授权失败，保持本票未完成，先修复原因；不将 secret 写进 Claude 配置作为兜底。

验证采用隔离实际应用和真实代理的用户结果；复用已有 Server、存储、安装器与 Keychain 注入边界。实现时运行两个共享包的必要测试；构建、模拟/fixture 与真实手机验收分别留证，不为拆票增加无关抽象。

## 执行边界

本轮为 to-tickets 整理，未授权开始第二阶段。实施确认后只领取所有 Blocked by 已完成的票，领取写 Owner，全部验收具备证据后才写 Progress: completed。全部工作使用隔离商店 target 和配置；直接版构建、签名、Sparkle、行为不变，不替换日常应用，不占 9876/9877，不改真实代理配置或凭据，不新增临时例外、第二安装包或 bridge，不提交/推送/同步/发布。日志和票不含 token、key 或用户目录内容。具体源码定位、命令与执行证据留在实施方案和验收记录中。

## Comments

- 2026-09-08：由 SPEC-store-v1 拆出，取代 02–08 候选票。

- 2026-09-08 Codex 第一阶段静态评估（未领取、未实施）：删除 cat token、明文 token fallback、rm -i 审批样例和“所有失败 1 秒”的错误验证。实际 approval-hook.sh 上限 30 秒；非 401 不能证明成功。补 Presence 与真实 CLI 后续行为证据，13 仍是硬关卡。 详见修订后的 IMPLEMENTATION-PLAN.html 票 13；实现与验收仍未执行。

- 2026-09-08 to-tickets：依据 Spec v2 重写为可验证的用户行为切片，保留编号、历史 Comments 和未领取状态；当前正文替代此前分歧建议，具体实现方法仍需实际验证。Status 调整为 ready-for-agent；不代表已确认实施。

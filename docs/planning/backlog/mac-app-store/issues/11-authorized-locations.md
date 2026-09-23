# 11 — 外部目录授权可记住、撤销并恢复

Status: ready-for-agent
Progress: not-started
Priority: next-cycle-important
Owner: unassigned
Blocked by: 09 商店版启动后可与 iPhone Pairing
Spec: Spec v2（本工作线综合稿）

## What to build

用户在 Settings 选择 Claude 与 Codex 配置目录后看到正确授权状态，重启可恢复；跳过、撤销或访问失效时知道哪些观察能力不可用，并能重新授权。目录授权覆盖安装器在配置旁备份与原子替换所需权限。

## Acceptance criteria

- [ ] 系统对话框可选择隐藏目录和任意隔离配置目录，界面有路径输入/显示隐藏项引导；不以单文件授权替代父目录权限。
- [ ] 分别授权两目录并重启应用，仍能访问已授权位置，不重复弹选择对话框。
- [ ] 跳过一项只影响依赖它的功能；Settings 与 ObservationHealth 区分未授权、未配置及健康状态，不显示虚假的无任务或全部完成。
- [ ] 移动后若 bookmark 仍有效则继续访问并更新持久状态；实际拒绝、丢失或撤销后停止访问、显示恢复入口，重新授权可恢复。
- [ ] 在授权目录内完成无害测试文件的创建、同目录原子替换与本次文件清理，证明安装所需访问范围；不修改真实配置。
- [ ] 授权释放与长期访问生命周期成对；直接版路径不变，日志不记录目录内容。

## Readiness and verification

本票不启动尚未实现的 Desktop 观察；15 将同一授权接入真实 watcher。

验证采用隔离实际应用和真实代理的用户结果；复用已有 Server、存储、安装器与 Keychain 注入边界。实现时运行两个共享包的必要测试；构建、模拟/fixture 与真实手机验收分别留证，不为拆票增加无关抽象。

## 执行边界

本轮为 to-tickets 整理，未授权开始第二阶段。实施确认后只领取所有 Blocked by 已完成的票，领取写 Owner，全部验收具备证据后才写 Progress: completed。全部工作使用隔离商店 target 和配置；直接版构建、签名、Sparkle、行为不变，不替换日常应用，不占 9876/9877，不改真实代理配置或凭据，不新增临时例外、第二安装包或 bridge，不提交/推送/同步/发布。日志和票不含 token、key 或用户目录内容。具体源码定位、命令与执行证据留在实施方案和验收记录中。

## Comments

- 2026-09-08：由 SPEC-store-v1 拆出，取代 02–08 候选票。

- 2026-09-08 Codex 第一阶段静态评估（未领取、未实施）：决定 a：改为 ~/.claude 与 ~/.codex 两个目录授权（隔离验证选对应测试目录），替代三个文件/目录位置；Python write() 在文件旁 mkstemp、backup、os.replace 是依据。bookmark 移动后可跟随，AC 改为仍可访问则恢复、失效则可修复；不执行原方案移动真实 ~/.codex 的命令。 详见修订后的 IMPLEMENTATION-PLAN.html 票 11；实现与验收仍未执行。

- 2026-09-08 to-tickets：依据 Spec v2 重写为可验证的用户行为切片，保留编号、历史 Comments 和未领取状态；当前正文替代此前分歧建议，具体实现方法仍需实际验证。Status 调整为 ready-for-agent；不代表已确认实施。

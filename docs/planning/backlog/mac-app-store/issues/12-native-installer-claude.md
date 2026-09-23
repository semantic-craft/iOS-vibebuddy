# 12 — 从 Settings 安装 Claude Hook 并收到真实事件

Status: ready-for-agent
Progress: not-started
Priority: next-cycle-important
Owner: unassigned
Blocked by: 10 商店版重启后保留 Pairing 与应用数据；11 外部目录授权可记住、撤销并恢复
Spec: Spec v2（本工作线综合稿）

## What to build

用户在商店 Settings 安装、修复或卸载 Claude Hook 与 Status line 包装，无需 Python。安装后真实 Claude 生命周期和 Status line sample 到达商店 Daemon，已有 Session 显示名称与上下文；完整手机审批闭环由 13 验收。

## Acceptance criteria

- [ ] 安装、重复安装、修复、卸载均可从 Settings 完成，提供成功或失败状态；应用不 spawn CLI 或 Python。
- [ ] 与受控 Python 样例对照，事件、matcher、参数、async、timeout 和已选审批门语义一致；混合组内他人 handler、其它设置和完整原 Status line 对象被保留。
- [ ] 审批默认 PermissionRequest，保留 AskUserQuestion 专用问题门；从样本版本提示低于当前最低版本 2.1.257 的用户升级，无样本/不可解析显示未知，不自行切回旧门。
- [ ] 真实隔离 Claude 执行安装生成的 exec-form 和 shell-string 命令后，事件通过认证到达 9880；Status line sample 丰富已有 Session，不创建 Session 或推进三态。
- [ ] 每条命令引用 bundle 资源并使用商店端口、token 文件与 support 位置；Claude 配置与日志无 token 原值，共享脚本不变。
- [ ] 写前备份、失败保持原配置；坏 JSON 不覆盖；卸载还原原 Status line。旧 wrapper 原备份无法安全取得时保持原配置并显示恢复入口。
- [ ] app 更新位置不变时命令继续有效，移动后显示修复；重复安装不递归包装。直接版安装入口和行为不变。

## Readiness and verification

优先复用现有安装与文件写入边界。命令注入不能破坏识别；只设置代理隔离环境变量不能保证 Python 金标准隔离，测试须受控覆盖所有读写位置。A1 若导致真实入站失败，先定因；13 仍须补独立探针与完整往返证据。

验证采用隔离实际应用和真实代理的用户结果；复用已有 Server、存储、安装器与 Keychain 注入边界。实现时运行两个共享包的必要测试；构建、模拟/fixture 与真实手机验收分别留证，不为拆票增加无关抽象。

## 执行边界

本轮为 to-tickets 整理，未授权开始第二阶段。实施确认后只领取所有 Blocked by 已完成的票，领取写 Owner，全部验收具备证据后才写 Progress: completed。全部工作使用隔离商店 target 和配置；直接版构建、签名、Sparkle、行为不变，不替换日常应用，不占 9876/9877，不改真实代理配置或凭据，不新增临时例外、第二安装包或 bridge，不提交/推送/同步/发布。日志和票不含 token、key 或用户目录内容。具体源码定位、命令与执行证据留在实施方案和验收记录中。

## Comments

- 2026-09-08：由 SPEC-store-v1 拆出，取代 02–08 候选票。

- 2026-09-08 Codex 第一阶段静态评估（未领取、未实施）：决定 b 已回写：默认 PermissionRequest，StatusLineSample.swift 当前无 version 字段，补版本诊断并保留未知状态。源码 group() 是 exec-form，不是候选声称的 shell-string；Python 不读取 CLAUDE_CONFIG_DIR，原隔离金标准方法不安全。补状态行备份跨版接管、保留混合组和明确 approval 入口。 详见修订后的 IMPLEMENTATION-PLAN.html 票 12；实现与验收仍未执行。

- 2026-09-08 to-tickets：依据 Spec v2 重写为可验证的用户行为切片，保留编号、历史 Comments 和未领取状态；当前正文替代此前分歧建议，具体实现方法仍需实际验证。Status 调整为 ready-for-agent；不代表已确认实施。

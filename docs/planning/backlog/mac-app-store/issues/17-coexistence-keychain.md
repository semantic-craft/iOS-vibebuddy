# 17 — 两版接管 Hook 不争抢，Keychain 状态如实呈现

Status: ready-for-agent
Progress: not-started
Priority: next-cycle-important
Owner: unassigned
Blocked by: 09 商店版启动后可与 iPhone Pairing；12 从 Settings 安装 Claude Hook 并收到真实事件；13 关卡：真实 Claude 任务从手机批准、拒绝与回答；14 Codex CLI 可从手机放行，其它 CLI 可观察
Spec: Spec v2（本工作线综合稿）

## What to build

用户切换 Hook 拥有者后，一个真实请求只由当前版本接收，原 Status line 与用户设置不被破坏；两版 Pairing 独立。API key 能否继承先验证，不能在签名不变边界内成立时如实引导重输，不承诺未经验证的共享。

## Acceptance criteria

- [ ] 隔离 direct→store 与 store→direct 安装均完成接管，当前配置仅有正确拥有者命令并显示提示，不新增运行时协商服务。
- [ ] 重复安装与旧拥有者卸载不会破坏当前配置；他人 Hook 和原 Status line 对象可恢复，无递归 wrapper。
- [ ] 两版隔离实例各有端口和 Pairing，避开 9876/9877；一次真实审批只由当前 Hook 拥有者收到并应答。
- [ ] 跨容器原命令备份不可取得时保留原配置并显示恢复入口，不凭空删除原 Status line。
- [ ] 使用虚构 Keychain 条目与隔离签名产物验证，只输出 OSStatus 和相等结果；不读取真实 key，不把虚构条目成功当旧凭据已继承。
- [ ] 若不能在当前边界内共享，说明原因并验证重输引导；需要修改直接版签名或迁移凭据时先提交具体候选，不自行执行。
- [ ] 直接版构建、签名与 key 读写逻辑保持不变，且所有已实现 CLI 的接管结果都有记录。

## Readiness and verification

转 ready-for-agent 前需解决未修改直接版能否满足双向接管/卸载所有权，以及 Keychain 的可行分支。已有重输分支不授权改变直接版签名。标题取消“必然无需重输”的未证承诺。

验证采用隔离实际应用和真实代理的用户结果；复用已有 Server、存储、安装器与 Keychain 注入边界。实现时运行两个共享包的必要测试；构建、模拟/fixture 与真实手机验收分别留证，不为拆票增加无关抽象。

## 执行边界

本轮为 to-tickets 整理，未授权开始第二阶段。实施确认后只领取所有 Blocked by 已完成的票，领取写 Owner，全部验收具备证据后才写 Progress: completed。全部工作使用隔离商店 target 和配置；直接版构建、签名、Sparkle、行为不变，不替换日常应用，不占 9876/9877，不改真实代理配置或凭据，不新增临时例外、第二安装包或 bridge，不提交/推送/同步/发布。日志和票不含 token、key 或用户目录内容。具体源码定位、命令与执行证据留在实施方案和验收记录中。

## Comments

- 2026-09-08：由 SPEC-store-v1 拆出，取代 02–08 候选票。

- 2026-09-08 Codex 第一阶段静态评估（未领取、未实施）：票原文要求改直接版 entitlement，与本次明确边界冲突；现有 KeychainStore 无 access group，删除预设迁移与读取真实 key 的验证，改隔离虚构值验证、必要时提交具体决策或按已有重输分支。补 Blocked by 13 硬关卡和 14（需对所有已实现安装器做双向接管）；Python 当前识别规则不保证所有权安全。 详见修订后的 IMPLEMENTATION-PLAN.html 票 17；实现与验收仍未执行。

- 2026-09-08 to-tickets：依据 Spec v2 重写为可验证的用户行为切片，保留编号、历史 Comments 和未领取状态；当前正文替代此前分歧建议，具体实现方法仍需实际验证。Status 调整为 needs-triage；不代表已确认实施。

- 2026-09-08 Claude triage（未领取实施）：三个未知均已实测，详见 [evidence/triage/TRIAGE-14-15-17.md](../evidence/triage/TRIAGE-14-15-17.md)。
  Keychain：用虚构条目与两个同 team（LQAVR62TK2）签名探针实测，沙盒商店 app 读不到未沙盒直接版写入的 legacy keychain 条目——关闭交互时 `errSecAuthFailed (-25293)`，开启交互时进程无限挂起且无可见对话框；data-protection 路径对沙盒侧是 `errSecItemNotFound (-25300)`，对未沙盒直接版是 `errSecMissingEntitlement (-34018)`。沙盒侧写同名条目得 `errSecDuplicateItem (-25299)`，即既读不了也覆盖不了。裁定走票中已允许的**重输分支**：商店版使用独立 service 名，UI 引导重新输入并说明原因；不改直接版签名，不迁移凭据。实现约束：任何 keychain 读取先关交互，否则商店 app 会挂死。正式 MAS 签名带 provisioning profile 后 data-protection keychain 对商店自身存储是否可用，实施时用正式签名复验，不以本地 Developer ID 结果代替。测试条目已删除，真实 `com.vibebuddy.secrets` 全程未读未写。
  双向接管：成立。Codex 靠 basename+argv 识别（见票 14），Claude/Grok/Qwen/Kimi/Antigravity 靠子串 marker，路径无关；`install()` 用 `owned == [expected]` 比较，路径不同即整组替换，不产生重复 hook。
  Status line：跨容器**不会**递归包装（已有 wrapper 时 `install_statusline` 返回 False），但 `uninstall_statusline` 在自己 SUPPORT_DIR 找不到备份时执行 `data.pop("statusLine")`，实测把用户原状态行整个删掉。商店原生实现**不得照搬该兜底**：无备份时保留现有 wrapper 并显示恢复入口；安装时若发现 statusLine 已是对方版本的 wrapper，提示先在该版本卸载，不接管自己无法还原的配置。
  仍受 13、14 阻塞；本条只解除 triage。

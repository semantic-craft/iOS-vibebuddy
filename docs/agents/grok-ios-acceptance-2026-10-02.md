# GROK-04 iOS 接入状态验收 — 2026-10-02

后续：[1.3.34 手机安装与朗读回归记录](../qa/grok-mobile-1.3.34.md)已解决下文
两项朗读测试失败。最新干净集成分支全量为 184 tests、5 skipped、0 failures；
Hermes 已安装并启动 1.3.34 (69)，源码已推送。以下保留首次验收时的历史状态。

工单在 `07b0df50` 发布，实现在 `a803d71b` 提交，来源切换修正在
`8f0cf119` 提交。完成后按本地工单规则删除 GROK-04 文件及索引行；原始要求
可在发布提交中查看。父工单 GROK-01 保持原样。

## 已实现

- 收件箱承接可选的 `Snapshot.grokMonitoring`。没有正式任务时也显示 Grok
  入口、发现的项目和等待接入说明，发现记录不计入任务数。
- 显示未开启、未找到、配置异常、等待活动、等待接入和已连接状态。异常保留
  daemon 提供的原因；指引用户在 Mac 的 Agent 接入设置开启或重试，以及在
  Grok 中 `/hooks` → `r` 重载。已有账户额度与监控的区别写在开启指引中。
- 状态卡片随 agent 选择显示；真实任务沿用原列表。断线保留状态并标明上次
  快照；旧快照缺失字段、切换 Mac、忘记配对及 Demo 清理旧状态。
- 中文、英文、稳定 accessibility identifier、VoiceOver 分组及现有设计 tokens。

## 运行验证

XcodeGen 及 iOS Simulator Debug 编译通过。最终代码的两项
`GrokMonitoringPhoneTests` 通过，覆盖流式快照、老协议字段缺失、不同
`sourceID` 首帧、断线保留、切换配对、忘记配对和 Demo 清理。另渲染了
accessibility3 字号的错误与发现卡片，图像保存在测试结果附件中。

全量 iOS suite 跑了一次：169 tests，3 skipped，5 assertion failures，涉及
两个 PhoneAnnouncerPlaybackTests。单独复测相同两个朗读测试仍有同样五个
断言失败；朗读实现与测试文件没有本次差异。未执行干净基线，不能以此证明
失败已在基线上存在。最终复测中 Grok 两项测试均通过。

隔离 daemon 使用端口 18864、一次性 HOME，通过 verify-vibebuddy doctor。
新建一次性 iPhone 18 Pro 模拟器连接这个真实 daemon 的 WebSocket，未连接
生产服务。核对了以下运行截图和快照：

1. 只读复制当前真实 Grok 的活跃注册表：任务数 0、Grok 入口可见，显示
   `glaux-book` 已发现等待接入及重载指引。
2. 隔离 HOME 启动真实 `grok agent --no-leader stdio`，只调用 initialize 和
   session/new，不发送模型提示。原生 SessionStart hook 到达 daemon 后，手机
   显示连接数 1 与正式会话数 1，原来的发现项目仍独立等待。
3. 在一次性配置中注入已保存错误，核对中文界面显示原因和 Mac 重试指引。
   这是错误状态显示验收，不是复现生产文件系统写入失败。
4. 卸载隔离 Grok hooks 后，手机显示监控未开启、任务数 0 和 Mac 开启指引。
5. 停止隔离 daemon 后，手机明确显示离线及“显示上次快照”。

Xcode 27 的 Device Hub 在 Computer Use 中多次返回 timeoutReached，无法读取
窗口；因此实际截图由 `simctl io screenshot` 获取并逐张检查。未声称通过
Computer Use 点击 agent 筛选，也未做真机、VoiceOver 实机操作或安装版验收。

运行日志、无凭据快照及截图保存在
`~/Projects/_shared-work/iOS-vibebuddy/2026-10-02-grok-ios/`；会话工作目录为
`.scratch/grok-ios/`。daemon、临时认证副本、一次性 HOME 与新建模拟器已清理。

## Standards

独立评审发现一项 P2：来源清理可能误删新 Mac 首帧的 Grok 状态。赋值已移至
清理之后，并补充连续 `sourceID` 切换回归。复核 `07b0df50...8f0cf119`
确认解决，无新增可行动问题。

## Spec

独立评审同样发现首帧状态丢失，与工单要求不符。修正后复核确认解决，无其他
缺失、错误实现或范围扩张。两个评审均为只读静态检查，运行证据由主任务提供。

Standards：1 项已解决，0 项未解决；Spec：1 项已解决，0 项未解决。

## 交付状态

源码与记录在当前分支本地提交；未推送、发布或替换 Mac/iPhone 安装版。
当前工作区还有其他任务改动，已保留且未纳入本次提交。构建与测试基于该工作区，
不是上述提交的干净 checkout。

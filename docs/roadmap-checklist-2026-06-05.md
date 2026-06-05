# VibeBuddy 优化路线 Checklist (2026-06-05)

来源:Vibe Island v1.0.37 逆向文档对照 + 本次会话声音包落地后的延伸。
**定位:全平台免费**——功能对标并力求超越 Vibe Island(它收费,我们不收)。
因此:无 License / IAP / 付费墙,iOS 支付审核雷区不存在,审核面更干净。
标签:`[iOS]` 必须过审 / `[Mac]` 自由 / `[Kit]` 共享 / 工作量 `S/M/L`。
⚠️ = App Store 审核风险点。✅ = 已确认安全。

---

## 0. 基线(本会话已完成)

- [x] `[Kit]` `SoundPolicy` 引擎 + `NotificationSound`(全部 6 声 + 规则,21 单测)
- [x] `[iOS][Mac]` 6 声接入两端;前台呈现代理;APNs 推送带匹配声音
- [x] `[iOS][Mac]` 设置:Play sound + Quiet mode(无音量滑块)
- [x] 宠物已从 Lottie 猫改为 SF Symbol 实时绘制(过审友好,保持)

---

## 1. ⭐ 最高杠杆:真实"失败/卡住"信号(解锁声音和宠物)

> 现状:`HookEvent.Kind` 无 failure(`HookEvent.swift:8`),reducer 只有 working/needsResponse/done,
> `agent_stuck` 只能靠 summary 关键词启发式。Vibe Island 捕获 `PostToolUseFailure` + 9 种 status。

- [ ] `[Mac]` `M` hook 解析 `PostToolUse` 的 `tool_response`(Bash 非零退出/错误)与 `Stop` reason
- [ ] `[Kit]` `S` `AgentSession` 加 `failed`/`.stuck` 语义(供声音 + 宠物 + 手机显示共用)
- [ ] `[Kit]` `S` `SoundPolicy.agentStuck` 改用真实信号,移除/降级关键词启发式
- [ ] `[iOS][Mac]` `S` 手机/Mac 准确显示"卡在 X"
- **依赖**:第 3、4 节的"宠物 stuck 态""状态细化"都建立在这条之上,建议先做。

---

## 2. 手机版 — 声音跟上 🔊 [iOS, 全部 ✅ 安全]

> 现状缺口:Mac 只在 needsResponse 时推送,手机**后台听不到** done/stuck/long-wait;
> 手机 mute 也管不到后台推送声。

- [ ] `[Mac][iOS]` `M` **后台声音补全**:Mac→手机 APNs 推送扩展到 done/stuck/long-wait,
      payload 带对应 `.caf`,让 6 声包在后台也完整
- [ ] `[Kit][iOS]` `S` `DeviceRegistrationPayload` 增加 `quietMode`/`playSound`,
      上报给 Mac → 推送尊重手机端偏好(解决"手机静音管不到后台")
- [ ] `[iOS]` `S` **触感**:前台 cue 触发 `UINotificationFeedbackGenerator`;
      夜间"只震动"选项(对应原 spec 的"静音/只震动")
- [ ] `[iOS][Mac]` `M` **定时静音**:Quiet mode 加时间段(如 22:00–08:00 自动只留 approval)
- [ ] `[iOS][Mac]` `M` 按 project/source 静音(后续)
- [ ] ~~音量滑块~~ — 明确搁置(`UNNotificationSound` 不支持逐音控音量)

---

## 3. 宠物跟上 🐾 [iOS + Mac · 双端同步 · 代码绘制 0 授权]

> 现状:`BuddyView`(iOS)用 SF Symbol 画 4 态(needsResponse/working/done/sleeping);
> Mac 还没有宠物。声音包已能区分 approval/question/stuck/long-wait,宠物表情没跟上。
> 原则:状态逻辑放 `[Kit]` `BuddyState` 双端共享,渲染各端原生(iOS SwiftUI / Mac SwiftUI+AppKit)。

**共享状态层**
- [ ] `[Kit]` `M` **状态对齐声音**:`BuddyState` 扩展 approval(警觉)/question(好奇)/
      stuck(担忧)/longWait(不耐烦) — 依赖第 1 节的 waitKind/failed 信号
- [ ] `[Kit]` `S` 抽出宠物外观映射(state→表情/徽章/口吻),iOS+Mac 同一套来源

**iOS**
- [ ] `[iOS]` `M` **声音+宠物联动**:cue 触发时宠物做对应微动作
      (needs_answer 轻跳 / agent_stuck 垂头 / agent_done 开心一跳)
- [ ] `[iOS]` `S` 空闲呼吸/眨眼等 idle 微动画,让它"活着"(无第三方美术)
- [ ] `[iOS]` `S` 保持 `accessibilityHidden`,但状态文案要可被 VoiceOver 读到

**Mac(同步宠物)**
- [ ] `[Mac]` `M` Glance 窗口里放宠物(`GlanceView`),与 iOS 同状态同表情
- [ ] `[Mac]` `M` **菜单栏图标随宠物状态变化**(working/needs/stuck/done 不同神态)——
      Mac 最自然的宠物落点,接近"灵动岛"质感
- [ ] `[Mac]` `S` 声音+宠物联动同 iOS(cue 触发时 Glance 宠物做微动作)

**共同(可放后)**
- [ ] `[iOS][Mac]` `L` 升级为代码绘制的原创小吉祥物(Canvas/Shape,非 SF Symbol pawprint),
      仍 0 授权风险 — 较大设计投入

---

## 4. Mac 版 — 自由扩展 🖥️ [Mac]

- [ ] `[Mac]` `M` **智能抑制升级**:用 session 的 `terminalRef` 判断"那个终端是否最前窗口",
      比现在的 `NSApp.isActive` 更准(`SoundPolicy.appActive` 的来源)
- [ ] `[iOS][Mac]` `M` ✅ **审批加"始终允许 / 本会话全部允许"**:写入 `PermissionRules` allow,
      手机/Mac 都受益(控制自己的 Mac,不涉 IAP)
- [ ] `[iOS][Mac]` `M` ✅ **会话状态细化显示**:用 `toolName` surface "正在编辑 refund.ts / 搜索中 / 压缩上下文"
- [ ] `[Mac]` `S` 空闲清理做成设置项(reducer 已有 `staleAfter`,暴露 30m–24h/从不)
- [ ] `[Mac]` `M` Sparkle 自动更新 — ⚠️仅当 Mac 走**直接分发(非 MAS)**
- [ ] `[Mac]` `M` 更多终端覆盖(Warp/WezTerm/Kitty;OSC2 标题 hack)
- [ ] `[Mac]` `M` Onboarding 环境检测(检测装了哪些 CLI/终端 + hook 是否注入成功)
- [ ] `[Mac]` `S` 核对 hook 注入带 marker 且可逆(Vibe Island 用 `# managed, do not remove`)

---

## 5. 过审 — 红线 [iOS]

> 全免费 → 无 IAP/付费墙,Vibe Island 那套 License/Lemon Squeezy 完全不抄。
> 审核只剩"无私有 API + 隐私合规 + 可体验"这些常规项。

- [ ] ✅ **保留 demo 模式**(reviewer 无需配对即可体验)— 已做对,别回退
- [x] `[iOS]` `M` 本地化 .lproj(iOS UI 已加 zh-Hans,英文为 base,2026-06-05);⬜ 商店元数据 en/zh-Hans(App Store Connect,HITL)
- [ ] ⚠️ 若加分析(PostHog 类):进隐私营养标签 + tracking 类目 opt-in(或干脆不加)
- [ ] 不抄:终端跳转 / 写 CLI 配置 / SSH(iOS 无权限,本就做不了)

---

## 执行进度（2026-06-05 落地）

本轮按 `/goal 执行 checklist 12345` 实现。Kit 59 + Mac 133 单测全绿，两端 app 均 BUILD SUCCEEDED。

- **§1 失败信号 ✅** `AgentSession.failed` + `HookEvent.toolError` + `HookParser` 检测
  tool 错误 + reducer 在 stop 时定型 + 共享 `FailureHeuristic`；`SoundPolicy.agentStuck`
  改用真实信号；iOS/Mac 会话行显示「卡住/Stuck」。
- **§2 手机声音 ✅** Mac 轮询用 `phonePolicy` 把完整 6 声推给手机，按设备 prefs 过滤
  （`DeviceTokens` 存 playSound/quietMode，空 sound = 静音推送）；iOS 上报 prefs +
  前台抑制远端推送（防双响）+ 触感（`Haptics`）+ 夜间定时静音（`QuietHours`，两端 UI）。
- **§3 宠物双端 ✅** `BuddyState` 扩展 approval/question/longWait/working/stuck/done/sleeping
  + 共享 `badgeSymbol`/`BuddyAccent`；iOS 宠物新表情 + 呼吸 idle + cue 联动 pulse；
  Mac 菜单栏图标随状态 + Glance 内宠物。
- **§4 Mac 扩展 ◐** 已做：卡住显示、空闲清理设置项（30m–24h/Never）、Glance 关闭按钮+
  全局快捷键(⌃⌥⇧⌘G)+菜单开关。**延后**（已记下）：审批「始终允许」(要写 ~/.claude/settings.json)、
  按前台终端的智能抑制、tool 活动详情、更多终端、Sparkle、onboarding。
- **§5 过审 ✅** 已核验：无支付/无分析/无 StoreKit/无 tracking（全免费，零 IAP 风险）；
  隐私串齐全；demo 模式在。**.lproj 本地化 ✅**（2026-06-05 iOS UI 全量加 zh-Hans，
  英文为 base/dev language，~65 串，中文模拟器验证；前判“iOS 中文硬编码”已过时——实为英文）。
  **Mac app 本地化 ✅**（2026-06-05，镜像 iOS：`zh-Hans.lproj` 107 串 + 不自动本地化处转
  `LocalizedStringKey`/`String(localized:)`；BUILD + 解析 + 键对账通过；待人工强制 zh-Hans 目视）。
  **延后**：商店元数据 en/zh-Hans（App Store Connect，HITL）。
- **附加（用户本轮新增）✅** Glance 关闭按钮 + ⌃⌥⇧⌘G 全局开关（解决 iMac 遮挡）；
  多 CLI 支持：`AgentKind` 扩展到 claude/codex/qwen/kimi/antigravity/grok/opencode/copilot
  + `fromSource` 路由 + 每 agent 名称/图标 + `docs/multi-cli-hook-setup.md`（注入安装为后续）。

## 建议执行顺序

1. **第 1 节 失败信号**(解锁声音准确 + 宠物 stuck 态,是其他项的依赖)
2. **第 2 节 后台声音补全 + 触感**(手机声音真正完整)
3. **第 3 节 宠物双端对齐 + 联动**(iOS + Mac 同步,宠物跟上声音)
4. **第 4 节 审批"始终允许" + 状态细化**(高频痛点,两端受益)
5. 其余按需(Sparkle / 本地化 / 终端覆盖 / onboarding)

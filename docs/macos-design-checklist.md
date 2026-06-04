# vibebuddy macOS — 设计打磨 checklist

基于 `ceorkm/macos-design-skill` 的思路。该 skill 偏 web/CSS(backdrop-filter、CSS 变量、`<kbd>`),这里**翻译成原生 SwiftUI/AppKit**,并对照我们实际的四个面:① 菜单弹窗 `MenuContent` ② Dashboard 窗口 ③ Settings ④ Glance HUD。

图例:✓ 已满足 · ☐ 待做

---

## P0 — 你点名要的:配对状态 + 手机名
- ☐ **菜单弹窗显示配对状态**:已配对 → 绿点 +「已配对:<手机名>」;未配对/没手机连 → 灰点 +「未配对」。
  - 实现:iOS 端注册时上报设备名(`UIDevice.current.name`,如「张三的 iPhone」)随 `POST /device` 或 WS 首帧发给 Mac;Mac 端 `DeviceTokens`/store 记「已配对手机(名 + lastSeen)」;`MenuContent` 顶部显示。
  - 命中 skill 的 **Progressive disclosure**(只在有意义时显示状态)。
  - 这是个真功能(iOS+Mac 两端),不是纯样式 → 单独一条,建议先做这条。

## 视觉(Visual)
- ☐ **Vibrancy / 材质**:弹窗 / Dashboard 侧栏 / glance 用 `Material`(`.regularMaterial`/`.bar`/`.ultraThinMaterial`)替代纯色,拿到原生 NSVisualEffect 质感。(glance 现在是纯黑 `.black`,可评估半透明材质但保证可读)
- ☐ **独立暗色**:全用语义色(`.primary`/`.secondary`/`Color(nsColor: .separatorColor / .textBackgroundColor)`),**不硬编码 hex**;明暗各自合理(skill 强调「暗色要更多层次,不是反色」)。审 Dashboard/Settings/MenuContent。
- ☐ **0.5px 边缘描边代替阴影**:卡片/分区 `.overlay(RoundedRectangle(cornerRadius: r).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))`。
- ☐ **圆角规范**:窗口 10 / 卡片 8 / 按钮 6 / 输入 6。审 glance、审批卡、Settings 表单。
- ☐ **8px 间距网格**:窗口 padding 16–20 · 分区 gap 24 · 卡片 gap 12–16 · 按钮 padding 6×12。
- ☐ **字号**:正文 13(macOS `.body`≈13)· 层级 Regular/Medium/Semibold/Bold。

## 布局(Layout)
- ✓ **Apple 三段式**:Dashboard 用 NavigationSplitView(侧栏 + 内容)。
- ✓ **工具栏区**:Dashboard 右上齿轮(Settings)已加。
- ✓ **Progressive disclosure**:Dashboard 空分区不显示(`if !sessions.isEmpty`)。
- ☐ 弹窗无会话时更精简(评估)。

## 交互(Interaction)— skill 强调「键盘优先」
- ✓ Open Dashboard 显示快捷键(Hyper+')· Cmd+, 设置 · Dashboard ⌘1/2/3 过滤 · 审批 a/d。
- ☐ 复核:**每个主操作都有快捷键 + 可见提示**(skill 的 `<kbd>` → 原生用次要文字显示组合键)。
- ☐ **动效统一**:ease-out `cubic-bezier(0.25,0.46,0.45,0.94)`(SwiftUI `.timingCurve(0.25,0.46,0.45,0.94, duration:)`)· fast 150ms / normal 250ms。审 glance 展开、列表 `.animation`。

## 逐面过一遍
- ☐ MenuContent · ☐ Dashboard · ☐ Settings · ☐ Glance —— 各自对照上面打勾。

---

**建议顺序**:先做 **P0(配对手机名)**(你点名 + 是真功能),再按「视觉 → 交互」批量打磨(多为小改,可一次性扫)。

# VibeBuddy 1.3.27 — macOS

- 看板以代理为第一维度：左侧代理轨列出 All agents 与每个在报到的代理，砖块外圈是该账号最紧的额度环，有会话等你处理时显示橙点；设置入口移到轨底。
- 工作台栏跟随选中的代理：名称与额度、以该代理名义新建任务、语音、五个 Library，下面是它的实时会话，按 Needs you / Working / Unread results / Idle 分组，可按项目和关键字筛选。
- 额度读数长在它所属的代理上，侧栏底部的 Account quota 面板取消；完整窗口、额度与花费仍在 Usage 页。
- Claude 额度只从状态栏的实时样本读取，不再调用无法返回额度面板的 `claude /usage`。状态栏未接入时直接显示"状态栏未接入"；过期的读数显示真实年龄（如 11d ago）而不是笼统的 stale。
- 所有提供方的已过期额度窗口按查看者时钟丢弃，不再只对 Grok 这样处理；读数刚重置、来源尚未报新窗口时显示"等待重置"。
- Grok Bot 只保留账号用量，不再观察会话。

包含 1.3.26 的全部修复。iPhone 对应版本为 iOS 1.3.25（55）。

## English

- The dashboard's first axis is the agent: a rail lists All agents and every agent that has reported in, each tile ringed by its account's tightest allowance, with an orange dot when a session needs you. Settings moved to the foot of the rail.
- The workbench column follows the selected agent: its name and allowance, a new task in its name, voice, the five Library entries, then its live sessions grouped Needs you / Working / Unread results / Idle, filterable by project and text.
- Allowance readings live on the agent they belong to; the sidebar's Account quota plinth is gone. Every window, credit and spend figure stays on the Usage page.
- Claude's allowance is read from the status line's live sample only; the `claude /usage` call, which no longer returns the quota panel, is retired. When the status line is not wired the reading says "Status line off", and a stale reading shows its real age (for example "11d ago") instead of a bare "stale".
- Expired allowance windows are dropped for every provider on the viewer's own clock, not only for Grok; a provider whose window has just reset shows "Awaiting reset" until the source reports the new one.
- Grok Bot keeps account usage only and no longer observes sessions.

Mac build 45. Includes all fixes from Mac 1.3.26. The accompanying iPhone release is iOS 1.3.25 (55).

# vibebuddy 1.3.14

> Draft for the next release. Version numbers are not bumped by this note.

- One visual language on every surface: neutral grounds, hairlines instead of shadows, the Geist face, and a status dot with a word for every state — on the Mac dashboard, menu panel, Glance and Settings, on the iPhone, on the Apple Watch and in the widgets and Live Activity.
- The iPhone dashboard is a flat, grouped task list (Needs you / Working / Done, or by project or agent) with a collapsible group per state and one composer; the Mac menu panel is the same list at panel size, with Needs you always open and older work folded away.
- The same rule decides what counts as current on every device: waiting, failed and running tasks always show; a followed task with an unread result stays while the Mac is still reminding you; anything else finished ages out after a day. The phone, the Watch, the island and the Mac now say the same numbers.
- The mic circle is the voice companion's entry everywhere (phone composer, Mac panel, dashboard and Glance). The cat keeps the app icon, the menu-bar mark and the avatar of a live conversation.
- Settings is ten pages under five groups, sized to read without scrolling, with a diagnostics summary on Phone & remote and arrow-key navigation; quota is read in the dashboard's plinth and Usage page only.
- Contrast reaches WCAG AA on every text and status token; the interface scales with Dynamic Type; touch targets on the phone are 44pt.
- Simplified Chinese covers the new Settings pages, the Usage page, the panel, the phone's approval menu, the Watch and the widgets; group names, state words and activity phrases read the same on every surface.

## Voice and summaries

- Mac completion-summary read-aloud adds Standard, Girl next door and Fiery girl styles for Doubao, Qwen and Gemini. Style is saved separately for each provider and used by both preview and automatic reading. Standard adds no delivery instruction; OpenAI has no style picker in this release.
- Historical conversation summaries offer Action briefing (default), Session review and Archive record. Saved summaries retain the style that generated them; changing the preference does not rewrite existing summaries.
- DeepSeek is available for text summaries. When summaries use DeepSeek, choose a separate read-aloud provider because DeepSeek has no speech integration here.

## 中文

- 三端一套视觉语言：中性底色、发丝线代替阴影、Geist 字体、每个状态一个状态点加一个词——Mac 的 Dashboard、菜单面板、Glance 与设置，iPhone，Apple Watch，小组件与实时活动全部一致。
- iPhone 首页改为平面分组任务列表（需要你 / 进行中 / 完成，或按项目、agent 分组），每组可折叠，底部一个作曲器；Mac 菜单面板是同一列表的面板尺寸版，「需要你」永远展开，更早的工作折到 Older。
- 三端用同一条规则判断哪些任务算当前：待回应、失败、运行中的任务永远显示；关注中且有未读结果的任务在 Mac 仍在提醒时保留；其余已完成任务一天后退出列表。手机、手表、灵动岛和 Mac 现在报同样的数字。
- 麦克风圆钮是所有端的语音伙伴入口（手机作曲器、Mac 面板、Dashboard、Glance）；猫保留在 App 图标、菜单栏标记和通话进行中的头像。
- 设置改为五组十页，尺寸按不滚动设计，Phone & remote 页有诊断摘要，侧栏支持方向键；配额只在 Dashboard 底座和 Usage 页读取。
- 所有文字与状态色对比度达到 WCAG AA；界面随系统字号缩放；手机点击区 44pt。
- 简体中文覆盖新的设置页、Usage 页、面板、手机审批菜单、Watch 与小组件；组名、状态词、活动词三端一致。

- Mac 完成摘要朗读新增「标准」「邻家小妹」「火辣少女」三档风格，支持豆包、Qwen 和 Gemini；按服务商分别保存，试听与自动朗读都会使用。标准不附加风格指令，本版 OpenAI 不提供风格选择。
- 历史对话摘要提供「行动简报」（默认）、「会话复盘」和「归档记录」三种写法；已保存摘要保留生成时的风格，切换偏好不会改写旧摘要。
- 文字摘要可选择 DeepSeek；使用它时须另选朗读服务商，本项目没有接入 DeepSeek 语音能力。

## Requirements and limits / 使用条件与限制

- The cat no longer appears on status surfaces by design; it is still the app icon and the voice companion's avatar. / 猫不再出现在状态面，属有意为之；它仍是 App 图标和语音伙伴的头像。
- "Older" work is folded, not deleted: notifications, deep links and acknowledgements still reach every session. / 「更早」的工作是折叠而非删除：通知、深链和已读确认仍能到达每个会话。
- Real-device acceptance of the redesigned iPhone and Watch screens is recorded separately; this note does not claim it. / 新界面的真机验收另行记录，本说明不作此声明。

- Styled speech has request-format and settings verification, but live provider audio and human listening acceptance remain outstanding. Delivery varies with the provider, model and voice; custom model/voice IDs may not support instructions. / 语音风格已有请求格式与设置验证，服务商真实音频及人工听感验收仍待完成；效果取决于服务商、模型和音色，自定义模型或音色可能不支持风格指令。

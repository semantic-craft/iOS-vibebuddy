# VibeBuddy 1.3.29 for iPhone and Apple Watch

## 简体中文

- 手机锁屏时，也能在手表上把正在跑的任务「停下」。
- 手机锁屏之后才开始的任务，现在打开手表 App 就能看到，不用先点进某个任务。
- 手表任务页的「返回总览」更可靠；手表列表每一行都标出是哪个 agent。
- Claude 行会显示「还有 N 项后台任务」和「已排定循环」，`/loop` 的轮次不再挂未读。
- Mac 重启后，手机上的 Grok 任务可以点「继续」重新接上。
- 手表上的问题、审批命令和回答选项完整显示，用表冠滚动查看；特别长的先显示一部分，点「显示更多」在原处展开。能在手表上批准的命令总是完整显示，读完才看到「批准」。任务详情新增结果片段（Mac 的摘要和 agent 回复的开头），长的可以点「展开」。
- 审批提醒会完整显示 160 字以内的命令或文件路径，更长的显示前 120 字并加上「…」。
- 无障碍：手表的审批和提问卡片里，内容和各个按钮分开朗读；iPhone 在最大字号下主页文字不再被截断，其他页面也大多能完整显示，批准 / 拒绝按钮不会被挤出屏幕；深色模式下薄荷绿按钮上的字改为深色，更清楚；打开「减少动态效果」后，滑入改为淡入，列表变化不再有动画；小按钮的点击范围扩大到 44pt。
- 语音：只有你在这一句里说出任务名，批准、拒绝、回答、指示才会执行；通话时长到顶时会说明原因，并可一键重拨。Gemini 已移除：之前选了 Gemini 的，语音伙伴会关闭，摘要需要重新选服务商，朗读改为系统语音。

## English

- Stop a running task from the Watch even while the iPhone is locked.
- A task that started after the phone was locked now shows up as soon as you open the Watch app, without opening a task first.
- "Back to dashboard" on the Watch's task page is more reliable, and every row in the Watch list names its agent.
- Claude rows show "N background tasks still running" and "Loop scheduled", and `/loop` turns no longer stay unread.
- After the Mac restarts, a Grok task started from the phone can be picked up again with Continue.
- The Watch shows questions, approval commands and answer options in full; scroll with the Digital Crown. Very long ones show a preview first, with "Show more" to expand in place. A command you can approve on the Watch is always shown in full, so you read it before you reach Approve. Task details now include result snippets (the Mac's summary and the start of the agent's reply), and long ones can be expanded.
- Approval alerts show commands and file paths of up to 160 characters in full; longer ones show the first 120 characters followed by "…".
- Accessibility: VoiceOver reads the Watch's approval and question cards and each button separately; at the largest text sizes the iPhone home screen no longer cuts text off, other screens mostly don't, and Approve / Deny stay on screen; text on mint buttons in dark mode is now dark and clearer; with Reduce Motion on, slide-ins become fades and list changes stop animating; small buttons have a 44 pt hit area.
- Voice: approve, deny, answer and instruct only go through when you name the task in that sentence. A call-length limit now ends the call with a reason and a one-tap redial. Gemini has been removed: if you had chosen it, the voice companion turns off, summaries need a provider again, and read-aloud uses the system voice.

iOS build 61. The accompanying Mac release is 1.3.34 (52).

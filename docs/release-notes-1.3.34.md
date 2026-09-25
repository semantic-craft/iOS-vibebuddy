# VibeBuddy 1.3.34 — macOS

- 审批提醒会完整显示 160 字以内的命令或文件路径，更长的显示前 120 字并加上「…」（原来截到 120 字，不带省略号）。Mac 自己的系统通知、推送到手机和手表的通知，以及 iPhone App 自己发的提醒（iOS 1.3.29 (61) 起）都是这样。
- 无障碍：开着 VoiceOver 时，提醒改发系统通知并会被朗读，不再只是几秒后就消失的刘海卡片（没开通知权限时仍退回卡片）。VoiceOver 能读出刘海速览和任务面板：打开的任务里来了新请求会播报，批准和拒绝键会读出要批准的命令，选中的选项会读作已选。
- 薄荷绿按钮上的字改成深色：深色模式下对比度从 2.06:1 提高到 9.09:1；刘海上的按钮和计数在两种外观下都这样，刘海也固定使用深色配色。打开「增强对比度」后，细线和次要文字会更清楚；打开「不单靠颜色区分」后，状态圆点会换成符号。
- 打开「减少动态效果」后，刘海展开改为短暂淡入，不再有弹簧和缩放；麦克风的循环动效会停下。
- 小字最小改为 10pt，朗读控制按钮的点击区域加大；刘海新增「展开速览」操作，VoiceOver 和全键盘操作都能用。

Mac build 52。配套的 iPhone / Apple Watch 版本为 iOS 1.3.29（61）。

## English

- Approval alerts show commands and file paths of up to 160 characters in full; longer ones show the first 120 characters followed by "…" (they used to cut at 120 with no ellipsis). This covers the Mac's own notifications, pushes to the phone and Watch, and alerts the iPhone app posts itself (from iOS 1.3.29 (61)).
- Accessibility: with VoiceOver on, alerts arrive as system notifications that are read aloud, instead of notch cards that vanish after a few seconds (they fall back to the card when notifications are off). VoiceOver reads the notch glance and the dashboard: a new request in the open task is announced, Approve and Deny read out the command, and chosen options read as selected.
- Text on mint buttons is now dark: 2.06:1 → 9.09:1 contrast in dark mode, and the notch's buttons and counts get the same fix in both appearances, with the notch now always using its dark palette. With Increase Contrast on, thin lines and secondary text stand out more; with Differentiate Without Color on, status dots become symbols.
- With Reduce Motion on, the notch opens with a short fade instead of a spring and scale, and the microphone's looping effect stops.
- Small text is at least 10 pt, read-aloud controls have larger hit areas, and the notch has a new "Expand glance" action for VoiceOver and Full Keyboard Access.

Mac build 52. The accompanying iPhone / Apple Watch release is iOS 1.3.29 (61).

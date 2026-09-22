# VibeBuddy 1.3.27 for iPhone and Apple Watch

## 简体中文

- Cursor 的额度现在两个池子都显示。Cursor 按"Cursor Models"和"Other Models"两笔独立额度计费，任何一笔用光都会让 Cursor 停下来。之前手表首页和小组件只显示其中一笔，而且挑的是排在前面的那笔——于是"Other Models"已经用光、Cursor 实际卡住时，手表上还写着"还剩 87%"。现在手表额度条、总览小组件都是一笔一行；只放得下一个数字的地方（锁屏圆环、手表复杂功能的单窗样式）显示更紧的那笔。
- 手表首页的额度条按每行自己的数字排序，不再按 provider 分组，所以宽裕的那行不会跟着紧的那行一起插到别的 agent 前面。
- 额度窗口过了重置时间就不再报数：环不会再拿重置前的百分比继续显示，旁白也不会再念"0% 剩余 · 现在"。
- 总览小组件多一行也装得下：一个 provider 一旦拆成两行，排版会自动收紧，最后一行不会被裁掉。

## English

- Cursor's allowance now shows both of its pools. Cursor bills two independent pools — Cursor Models and Other Models — and either one running to zero stops work. The Watch strip and the widgets used to draw only one of them, and they picked whichever came first, so a wrist could read "87% left" while Other Models was spent and Cursor was already blocked. The Watch strip and the overview widget now draw one row per pool; surfaces with room for exactly one number (a lock-screen circle, a single-window complication) draw the tighter pool.
- The Watch home strip is ordered by the number on each row rather than grouped by provider, so a pool with room no longer travels above another agent's tighter row.
- A window that has passed its reset reports nothing: the ring stops drawing the pre-reset percentage and VoiceOver stops saying "0% left · now".
- The overview widget fits its extra row: once a provider splits in two, the layout tightens instead of clipping the last row off the bottom.

iOS build 57. The accompanying Mac release is 1.3.31 (49).

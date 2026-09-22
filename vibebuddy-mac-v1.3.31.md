# VibeBuddy 1.3.31 — macOS

- Cursor 的额度现在两个池子都显示。Cursor 按"Cursor Models"和"Other Models"两笔独立额度计费，任何一笔用光都会让 Cursor 停下来，但界面一直只显示其中一笔——而且挑的往往是宽裕的那笔。实际后果是：当"Other Models"已经用到 100%、Cursor 其实已经卡住时，手表和侧边栏还在显示"还剩 87%"。现在只要地方够，两笔就各占一行；地方只够显示一个数字的地方（左侧圆环、锁屏小组件）显示更紧的那笔，并写出它的名字。
- 只显示一个数字的 Mac 界面不再被"子窗口"带偏。Claude 的单模型周、Codex 的 Spark 这类是同一笔额度的细分，不是独立额度；以前它们会参与"最紧的那个"的评选，于是一个用到 95% 的模型周能让 Mac 圆环显示 5%，而手表读真正的周额度还有 60%——两块屏对同一个账号各说各话。
- 手表首页的额度条改成按每行自己的数字排序。以前是先按 provider 排，于是 Cursor 宽裕的那行会跟着紧的那行一起被排到上面，压在别的 agent 更紧的行前面。
- 额度重置之后不再拿旧数字画图。窗口过了重置时间就不再报数，而不是继续显示重置前的百分比。

Mac build 49。配套的 iPhone 版本为 iOS 1.3.27（57）。

## English

- Cursor's allowance now shows both of its pools. Cursor bills two independent pools — Cursor Models and Other Models — and either one running to zero stops work, but the app only ever drew one of them, and usually the comfortable one. In practice that meant a wrist reading "87% left" while Other Models was spent and Cursor was already blocked. Every surface with room now draws one row per pool; surfaces with room for exactly one number (the rail ring, a lock-screen widget) draw the tighter pool and name it.
- The Mac's one-number surfaces are no longer thrown off by a scoped window. A Claude model-week or Codex Spark subdivides one allowance rather than being an allowance of its own, but they used to compete for "closest to running out" — so a model-week at 95% used could ring the Mac at 5% while the wrist read the real week at 60%, two screens disagreeing about one account.
- The Watch home strip is ordered by the number on each row. It used to order providers, so Cursor's comfortable row travelled with its tight sibling and sat above another agent's tighter row.
- A window that has passed its reset reports nothing instead of its old percentage.

Mac build 49. The accompanying iPhone release is iOS 1.3.27 (57).

# VibeBuddy 1.3.25 — macOS

- 从 Mac 或已配对的 iPhone 新建 Grok Build 任务，可远程处理审批、回答问题、完成后继续，以及停止当前轮次。运行中追加的指令会排到下一轮。
- 托管任务的完成正文可在结果面板中读取；同一会话的 hooks 不会重复创建审批卡或覆盖结果。
- 停止任务时撤回仍在等待的审批与问题，避免已结束的任务再次弹出卡片。

需要已安装并登录的 Grok Build CLI。仅托管 VibeBuddy 新建的会话；终端内已有的会话沿用 hooks，Mac 重启后不会自动恢复 ACP 控制。审批频率仍遵循 Grok 自身的权限配置。

## English

- Start a Grok Build task from your Mac or paired iPhone, handle approvals and questions remotely, continue after completion, or stop the current turn. Instructions sent during a turn are queued for the next one.
- Read hosted task results in the result pane. Hooks for the same session no longer create duplicate approval cards or overwrite the result mapping.
- Stopping a task withdraws pending approvals and questions, including requests still being prepared.

Requires an installed, signed-in Grok Build CLI. Hosting applies to sessions started by VibeBuddy; existing terminal sessions keep their hook behavior. ACP control is not restored after the Mac app restarts. Grok's own permission settings determine when approval is requested.

Mac build 43. Includes all changes from Mac 1.3.24. The accompanying iPhone release is iOS 1.3.24 (54).

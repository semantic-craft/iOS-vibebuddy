# 06: 真机验收与触觉证据

**What to build:** 在 Hermes（iPhone）与配对 Watch 上，把喊停、快捷回答、触觉与 Double Tap 各走一遍并留下证据；同时回答 spec Further Notes 第 2 项：通知长显示的自定义节奏是否稳定，决定触觉文案的承诺范围。

**Blocked by:** 02: Watch 喊停 Codex 会话；03: Watch 快捷回答；05: 触觉语言与 Double Tap

**Status:** ready-for-human（2026-09-24 已做一轮，见 Comments；还剩：锁屏停下（等 WR-08）、真实 Codex 停下、长显示触觉、批准时双指互点两下）

- [ ] 停止一个真实 Codex working Session：Watch 显示已发出 → 下一份快照变为 done；重复点击一次、断线一次、Session 已结束后再点一次，各自结果符合 accepted / refused / failed 口径。
- [ ] 预设短语与听写各回答一次真实问题；取消一次不发送；Mac 先回答后 Watch 再发被拒绝。
- [ ] 手机锁屏、Watch 佩戴时，四类事件各触发一次，记录抬腕长显示是否出现自定义节奏、是否可分辨；应用前台的跃迁节奏各一次。
- [ ] Double Tap 在允许、发送、停下确认三处各触发一次。
- [ ] 记录受测 iOS / watchOS / App 版本与通知设置；不可验证项如实列为未验证，不用模拟器结果替代。
- [ ] 依据触觉证据给出结论：长显示节奏稳定 → 文案可写"抬腕即分辨"；否则改为"打开 VibeBuddy 时"，并把结论回写 spec。

## Comments

- 2026-09-24：腕上部分合成一轮，共 6 步，见 backlog README「只剩你」第 1 件。第 1 步你数横幅展开（长显示）后又震了几下：抬腕前那一下归系统；展开时有一串（「需要你」是 5 个长拍）就是用了自定义节奏，展开时不震就是没用。agent 事先确认「需要你」提醒没关、不在安静时段（否则 `WatchHaptics.rhythm` 本来就返回空）。第 4 步快捷回答 + 双指互点两下发送，第 5 步双指互点两下批准，第 6 步停下 Codex + 双指互点两下确认。agent 负责记录 iOS / watchOS / App 版本和通知设置，并从诊断里记下第 1 步是不是冷启动（ADR-0033 的 8 s 等待）。
  - 照实记为未验：「完成」「出错」「额度不足」三类触觉。这一轮不产生完成提醒：wrist-qa 会话不发 Stop，你主动停下的 Codex 轮次不发完成提醒（`userStopped`）；另两类没有安全的真实触发方式。应用前台的跃迁节奏也未验。卡片里的听写（`WatchAnswerConfirmView`）未验，第 2、3 步用的是横幅的系统文字输入。
  - 边界情况由 Kit 测试覆盖，不交给你：重复点「停下」只打断一次（`WatchApprovalTests.testASecondStopTapDoesNotSendASecondInterrupt`、`DispatchTests` 的 stop 路由）；停下只作用于它瞄准的那一轮（`testAStopIsForwardedOnlyForTheTurnItWasAimedAt`）；被拒的停下会说出来，失败的可以重试（`testARefusedStopIsSaidOutLoudAndAFailedOneCanBeRetried`）；回答绑定到它针对的那道题，Mac 先答后手表再发会被拒（`testAnAnswerIsBoundToTheQuestionItWasWrittenFor`）。这些都没有在设备上走过。
- 2026-09-24 腕上一轮的结果（记录：`~/Projects/_shared-work/iOS-vibebuddy/watch-acceptance-2026-09-24/RESULTS.md`）：
  - 快捷回答：通过。卡片上选预设「Yes」，用双指互点两下发送，agent 收到「Yes」。
  - 双指互点两下：「发送」处通过；「停下确认」处用过，但手机锁屏时停下没送达（见 WR-08 / #292）；「允许 / 批准」处未验，你点的是横幅按钮。
  - 喊停：手机解锁时通过（托管 Cursor 任务 `061f9bdf`，12:04:55 记为 `userStopped`；来源是你的口述加 Mac 快照，停下本身不写手表诊断）。手机锁屏时失败，停下没到 Mac（[08](https://github.com/semantic-craft/iOS-vibebuddy/pull/292)）。Codex 那天额度用完，改用托管 Cursor 验。Mac 上停下的执行路径不同（Cursor 走 `cursorACP.cancel`，Codex 走 `monitor.interrupt`），**真实 Codex 停下仍未验**，9 月 25 日 09:00 额度重置后再跑。
  - 触觉：长显示有没有自定义节奏，你没数到，**未验**。「需要你」横幅震了，也有两次推送已被苹果接受但手表没震，原因不明：当时手机朝上，但同一时段另三次正常送达（见 WR-11 / #304）。
  - 新发现：[08](https://github.com/semantic-craft/iOS-vibebuddy/pull/292) 锁屏手机上的停下，[09](https://github.com/semantic-craft/iOS-vibebuddy/pull/305) 横幅「回复」直接打开 App，[10](https://github.com/semantic-craft/iOS-vibebuddy/pull/303)「返回总览」点了没反应，[11](https://github.com/semantic-craft/iOS-vibebuddy/pull/304) Mac 只等 25 秒。

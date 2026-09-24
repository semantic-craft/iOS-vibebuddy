# 06: 真机验收与触觉证据

**What to build:** 在 Hermes（iPhone）与配对 Watch 上，把喊停、快捷回答、触觉与 Double Tap 各走一遍并留下证据；同时回答 spec Further Notes 第 2 项：通知长显示的自定义节奏是否稳定，决定触觉文案的承诺范围。

**Blocked by:** 02: Watch 喊停 Codex 会话；03: Watch 快捷回答；05: 触觉语言与 Double Tap

**Status:** ready-for-agent

- [ ] 停止一个真实 Codex working Session：Watch 显示已发出 → 下一份快照变为 done；重复点击一次、断线一次、Session 已结束后再点一次，各自结果符合 accepted / refused / failed 口径。
- [ ] 预设短语与听写各回答一次真实问题；取消一次不发送；Mac 先回答后 Watch 再发被拒绝。
- [ ] 手机锁屏、Watch 佩戴时，四类事件各触发一次，记录抬腕长显示是否出现自定义节奏、是否可分辨；应用前台的跃迁节奏各一次。
- [ ] Double Tap 在允许、发送、停下确认三处各触发一次。
- [ ] 记录受测 iOS / watchOS / App 版本与通知设置；不可验证项如实列为未验证，不用模拟器结果替代。
- [ ] 依据触觉证据给出结论：长显示节奏稳定 → 文案可写"抬腕即分辨"；否则改为"打开 VibeBuddy 时"，并把结论回写 spec。

## Comments

- 2026-09-24：腕上部分合成一轮，共 6 步，见 backlog README「只剩你」第 1 件：第 4 步快捷回答 + 双指互点两下发送，第 5 步双指互点两下允许，第 6 步停下 Codex + 双指互点两下确认 + 触觉能否分辨。这一轮只产生「需要你」和「完成」两类触觉；「出错」和「额度不足」没有安全的真实触发方式，照实记为未验证。几条边界不交给你：「只有运行中的 Codex 能停、结束后不再给停下」有 Kit 测试（`SessionActionTests`），「Mac 先答后手表再发」也有（`WatchQuickAnswerTests.testAnAnswerTheMacAlreadyHandledIsSaidOutLoudAndNotResent`）；重复点「停下」、断线后再点、取消不发送没有专门的测试，也没有在设备上走过，照实记为未验证。

# vibebuddy — 实际进度审计 + 后续开发计划（2026-09-02）

本文取代 `roadmap.md` 顶部的 6 月 Status 段和 `docs/roadmap-checklist-2026-06-06.md`
作为当前唯一的"下一步"来源。判断依据是 2026-09-02 晚上对仓库、分支、worktree、
测试和本机运行态的逐项核对，不是交接文件的自述。

## 一、实际进度（按时间）

### 1. 6 月：v1 已交付，但发布链路没有闭环

- Mac 1.0 DMG 已挂在 GitHub Releases（2026-06-06），**未签名、未公证**（无 Developer ID 证书）。
- iOS 1.0 代码就绪（截图、文案、隐私政策、reviewer notes 都在 `docs/`），**未提交 App Store**：
  Apple Developer Program、App Store Connect 记录、TestFlight 等全是人工步骤，见
  `docs/app-store-submission-checklist.md`。
- 多 CLI hooks（Claude / Codex / Qwen / OpenCode / Grok / Kimi）verified live；Antigravity 上游阻塞，已决定不管。
- 语音伴侣、Live Activity 推送、always-allow、Sparkle 接线（密钥/appcast 未配，处于 inert）均代码完成。
- 约 20 个 `.scratch/*/issues` 停在 `IMPLEMENTED — pending human verification`：需要真机 / 目视 / 听测，
  从 6 月 6 日起一直没做。清单在 `docs/roadmap-checklist-2026-06-06.md` 末节。

### 2. 6/22 → 9/2：main 工作区里一直没提交的工作

main 工作区 dirty（43 个已跟踪文件 + 6 个新文件），内容是：

- Codex 改用官方生命周期 hooks（`~/.codex/hooks.json` 12 个事件，`hooks/install-codex-hooks.py`），
  删除 `codex-notify*.sh` 和 `CodexParser`，新增 `CodexRolloutMonitor` 初版。本机 hooks.json 已装。
- `VoiceCallCoordinator` 下沉到 Kit，Mac / iOS 两份 `VoiceChat.swift` 去重。
- `ToolActivity.label(for:)` 统一状态短语；Codex collaboration 工具名映射。
- 文档：`prior-art.md` 9/2 刷新、`hooks/README.md`、ADR-0009、skills 软链改造（`.claude/skills/*` 删除 + `.gitignore`）。

这份 dirty 内容 **逐字节等于** observability 分支的第一个提交 `fc4b77c`（只差 AGENTS.md 一个段落的位置）。
也就是说它已经在分支里，只是 main 上没提交。

### 3. 9/2：Codex + Grok 的 "Agent Observability V2" 冲刺

分支 `codex/agent-observability-v2`（11 个提交，主线 d295a9c 的严格后代，可快进）：

| Ticket | 内容 | 提交 | 状态（核对后） |
|---|---|---|---|
| 01 | Codex Desktop rollout 事件驱动监控 | 08068bb | 完成，真实 rollout E2E 已做 |
| 02 | 观察来源健康（hook / rollout / transcript / degraded） | 4cd8f30 | 完成 |
| 05 | 有界生命周期日志（7 天 / 250 条，0600） | 643e4c9 | 完成，重启恢复 E2E 已做 |
| 07 | Codex 用量适配器（app-server RPC） | 9bc21e3 | 完成，真实账号只读验证 |
| 08 | Claude 用量适配器（`/usage` CLI） | 5178a30 | 完成 |
| — | Codex Micro 五态投影（`TaskPresentation` / `TaskStatusSwiftUI`） | 589b894 | 完成；`.scratch/codex-micro-status-parity` 的 ticket 文件未回填 |
| 03 | Claude 父会话 / subagent 拓扑 | fb8c2a2 | **ready-for-human**：真机 iOS 子代理行、TeammateIdle、daemon 重启恢复未真实验证 |
| 06 | 本地通知 / APNs 投递健康 | 87005c5 | **ready-for-human**：无真实 iPhone token，APNs `accepted` 未实测 |
| 04 | Codex collaboration 拓扑 | d076df2 | Grok 做完但**未集成**，游离提交；现已保留为分支 `grok/observability-04-codex-collaboration`；缺真实 Codex Desktop collaboration E2E |

ticket 注释里引用的"来源提交链"（7dab11a、9a6a5af 等）都是已删除 worktree 里的游离对象，
不在任何分支上，会被 gc；分支上的集成提交才是真相。

### 4. 9/2 同日的两份新 PRD（未开工）

- **watchOS 伴侣**：`.scratch/watchos-companion/PRD.md` + 8 张 ticket + HTML 原型
  （分支 `prototype-2026-09-02`，`DECISION.md` 已定：A 默认首页 / B 紧急接管 / C 配额详情）。
- **架构边界重构**：`.scratch/architecture-boundaries/PRD.md`（6/13，Brooks-lint 77 分）+ 1 张 ticket。

### 5. 仓库结构问题

`origin/main` 是 7/9 重写过的公开历史（删掉 `.scratch/`、`.claude/`，并在 `.gitignore` 忽略它们），
与本地 main **没有共同祖先**（ahead 149 / behind 145）。本地现在无法正常 push；
observability 分支也基于私有历史。

## 二、今天实际跑过的验证

| 树 | VibeBuddyMac `swift test` | VibeBuddyKit `swift test` | Mac App xcodebuild | iOS Simulator xcodebuild |
|---|---|---|---|---|
| main（dirty 工作区） | 230 tests / 30 suites 通过 | 132 / 19 通过 | 未跑 | 未跑 |
| `codex/agent-observability-v2` | 292 / 36 通过 | 142 / 21 通过 | BUILD SUCCEEDED | BUILD SUCCEEDED |
| `grok/observability-04-codex-collaboration` | 296 / 36 通过 | — | — | — |

本机运行态：`/Applications/VibeBuddyMacApp.app` 是 **1.0 build 1（6 月版）**，当前**没有在运行**，
`:9876/health` 无响应。也就是说这台机器现在其实没有在监控任何 agent；分支上的所有新功能都还没装过机。

## 三、清理记录（2026-09-02）

| 对象 | 处理 | 理由 |
|---|---|---|
| grok worktree `observability-03-claude-topology`（d467d60） | 删除 | 内容已作为 fb8c2a2 cherry-pick 进分支，diff 只差 06 的文件 |
| grok worktree `observability-06-notification-health`（980dc68） | 删除 | 干净，且是分支祖先 |
| grok worktree `observability-04-codex-collaboration`（d076df2） | 先建分支 `grok/observability-04-codex-collaboration`，再删除 | 唯一未集成的提交，不能让它变游离 |
| codex worktree `~/.codex/worktrees/b17c`（分支 `codex/agent-observability-v2`） | 删除，**分支保留** | 未跟踪文件与主工作区完全相同，唯一多出的 `GROK_BUILD_PLANNER_PROMPT.md` 已复制回主工作区 |
| `.scratch/*` 未跟踪资料、`.brooks-lint-history.json`、`docs/icp-app-filing-checklist.md` | 原样保留 | 交接文件明确要求保留 |
| main 的 dirty 工作区 | 已快进并 rebase 到公开历史 | 见第六节 P0 执行记录 |

释放磁盘约 4.3 GB。分支保留：`codex/agent-observability-v2`、`grok/observability-04-codex-collaboration`、
`prototype-2026-09-02`。

## 四、后续开发计划

原则：先把已经写好的代码装到真机上验收并发布，再开新功能。Watch 的第 8 张 ticket 本来就要真机与发布链路，
先收口不是绕路。

### 阶段 0 — 收口仓库（半天；0.1 和 0.3 需要你拍板）

**0.1 main 快进到 observability 分支（含 04）。** main 工作区就是 fc4b77c 的快照，两条分支都是它的后代，
不需要 merge commit：

```bash
git stash push -u -m "safety: main dirty baseline 2026-09-02 (== fc4b77c)"
git merge --ff-only grok/observability-04-codex-collaboration
git checkout stash@{0}^3 -- .brooks-lint-history.json docs/icp-app-filing-checklist.md \
  .scratch/architecture-boundaries .scratch/codex-micro-status-parity .scratch/icon-candidates \
  .scratch/qa-shots .scratch/watchos-companion .scratch/watchos-companion-prototype \
  .scratch/agent-observability-v2/GROK_BUILD_PLANNER_PROMPT.md
git reset -q -- .
```

回滚：`git reset --hard d295a9c && git stash pop`。

**0.2 回填 ticket 状态。** 01 / 02 / 05 / 07 / 08 和 codex-micro 01 改 `done`；03 / 06 / 04 保持
`ready-for-human`，把阶段 1 的验收缺口写进去。删除 `GROK_BUILD_HANDOFF.html` 里"分支冻结、不得 merge"
的规则（那是给 Grok 的，现在已经失效）。

**0.3 解决公开 / 私有历史分叉。** 推荐以公开历史为准：先 `git branch main-private-2026-09-02 main` 备份，
再把 d295a9c 之后的提交 rebase 到 `origin/main` 上（冲突只在 `hooks/README.md`、`hooks/codex-notify*.sh`、
`.gitignore` 三处），最后一个提交 `git rm -r --cached .scratch` 让公开树保持干净。之后就能正常 push，
不再需要每次发布前手工重写历史。

**0.4 文档同步。** `CONTEXT.md` 增加新词汇（ObservationSource / ChildAgent / AccountUsage /
TaskPresentation / LifecycleJournal / NotificationDelivery）；`roadmap.md` Status 段指向本文。

### 阶段 1 — 装机验收（1–2 天；大部分需要你在场）

1. **Mac 装机**：`tools/redeploy-mac.sh` 构建并替换 `/Applications` 里的 1.0，确认 `:9876/health` ok，
   Settings 能看到 Observation health、Usage、Delivery log、Timeline。
2. **iOS 重装**：wire 协议变了（`childAgents`、observation 元数据、五态 `TaskPresentation`、
   `WidgetSnapshotStore`），手机上的 6 月版会缺字段。重新装到 iPhone，确认 dashboard / Live Activity /
   Widget 五态颜色。
3. **03 验收**：真实 Claude 单个 + 并发子代理，看 Mac / iOS 子代理行；`TeammateIdle` 目前没装 hook，
   决定是否补。
4. **04 验收**：真实 Codex Desktop collaboration（并发 spawn、wait-any、interrupt、父 turn 先结束、
   daemon 中途启动）。
5. **06 验收**：真实 iPhone token 下拿到一条 APNs `accepted`；本地通知 `scheduled` 横幅。
6. **6 月遗留人工清单**一次过：always-allow 实测、双终端前台抑制、Warp / kitty 跳转、
   Setup 标签页目视 + zh-Hans、iOS 语音听测、Live Activity 真机推送。

完成标准：03 / 04 / 06 三张 ticket 改 `done`；遗留清单逐条勾掉或写明缺口；发现的 bug 走 `tdd-bug-fix`。

### 阶段 2 — 发布 v1.1 与 iOS 上架（外部依赖，需要你的账号和密钥）

1. **Mac v1.1**：Developer ID Application 证书 → `notarytool` 公证 → Sparkle `generate_keys` +
   托管签名 appcast（`docs/sparkle-setup.md`）→ GitHub Release，附 observability + Codex hooks 更新说明。
2. **iOS**：Apple Developer Program → App Store Connect 记录 → 隐私标签 → TestFlight 内测 → 提交审核。
   逐步清单在 `docs/app-store-submission-checklist.md`，reviewer 素材已就绪。
3. **国区 ICP 备案**：只有决定上国区才做（`docs/icp-app-filing-checklist.md`）。

### 阶段 3 — watchOS 伴侣（下一个大功能）

`.scratch/watchos-companion/issues/01–08`，按依赖分四波：

| 波次 | Ticket | 前置 / 说明 |
|---|---|---|
| 1 | 01 可安装 Watch demo → 02 iPhone→Watch 状态中继 | 先冻结五态 snapshot 协议；中继只发投影，Watch 永不拿 Mac token |
| 2 | 03 实时状态 + 只读告警 ‖ 05 Codex 周配额 | 05 的输入改为分支上已验收的 `AccountUsage` |
| 3 | 04 一次性安全审批 ‖ 06 Claude 周配额 | **修 spec drift**：06 原文写的"本地 rate-limit cache"改为 08 已落地的 `/usage` CLI + `AccountUsage` |
| 4 | 07 后台 / 断连 / 通知可靠性 → 08 真机验收发布 | 08 需要真实 Apple Watch 与阶段 2 的发布链路 |

### 阶段 4 — 架构边界重构（按需切片，不整体做）

PRD 是 6/13 写的，observability 之后 `MenuBarModel` 又多了约 260 行。建议只做 Watch 需要的切片：
Kit 拆开 wire 词汇与 voice / settings；`MenuBarModel` 拆出 Usage / Delivery / Observation 协调。
其余条目等真正出现改动痛点再做，不为 PRD 而重构。

### 协作流程（给后续 Grok / Codex 会话）

每个任务的提示词、并行 / 串行编排和一行启动命令见 [`prompts-2026-09.md`](prompts-2026-09.md)；
worktree 用 `tools/agent-worktree.sh <name>` 建，集成后 `--remove`。

- ticket 仍放 `.scratch/<feature>/issues/`，Status 用五个固定字符串。
- 每个 agent 在**命名分支**上工作，不再用 detached-HEAD worktree；集成后立即 `git worktree remove`。
- 集成方式是快进或 merge 进 main，不再另立"集成分支"。
- 装机验收（installed app + 真实 agent + 真机）是 `done` 的唯一标准；自动测试通过只写"自动测试通过"。

## 五、需要你拍板的三件事

1. **现在把 main 快进到 observability 分支（含 04）吗？** 已执行（第六节）。测试全绿、Mac App 构建通过、内容是主线的严格后代。
2. **公开 / 私有历史以公开为准并 rebase 吗？** 已执行（第六节）。原推荐：是，一次性处理掉，否则每次发布都要重写历史。
3. **优先级：先发布 v1.1 / iOS 上架，还是先做 Watch？** 推荐：阶段 0 → 1 → 2 先收口，再进 Watch。

## 六、P0 执行记录（2026-09-02 晚）

全部本地操作，**未 push**。

- main 先快进到 d076df2（含 Ticket 04），再 `rebase --onto origin/main`。现在 main = origin/main + 13 个提交
  （12 个 observability 提交、`chore: stop tracking .scratch on the public history`、本次文档提交），`git status -sb` 只显示 ahead，不再 behind。
- 私有历史备份为分支 `main-private-2026-09-02`。`codex/agent-observability-v2` 与 `grok/observability-04-codex-collaboration`
  仍指向旧历史上的同内容提交，确认后可删。
- `.scratch/`（含 6 月全部 ticket）与 `.claude/` 现在是 gitignored 的本机资料，只存在于这台 Mac 和备份分支。
  `.gitignore` 里写 `.scratch`（不带斜杠），worktree 里的软链才会被忽略。
- rebase 冲突只有 `hooks/codex-notify*.sh` 的 modify/delete（按 checkpoint 的删除处理）；`.gitignore`、`hooks/README.md` 自动合并，
  公开版对个人绝对路径的替换已核对，追踪文件中不再含 `/Users/...`。
- ticket 回填：01 / 02 / 05 / 07 / 08 与 Codex Micro 01 → `done`；03 / 06 / 04 → `ready-for-human`（验收项见 `prompts-2026-09.md` P2）；
  `GROK_BUILD_HANDOFF.html` 顶部加了失效说明。
- `CONTEXT.md` 新增 Observability 词汇段；`tools/agent-worktree.sh` 已实测：建 worktree、软链 `.scratch` / `.claude/skills` / `.agents/skills`、`--remove`。
- 验证（rebase 后的 main）：VibeBuddyMac 296 tests / 36 suites 通过；VibeBuddyKit 142 / 21 通过；Mac App 与 iOS Simulator xcodebuild 均 BUILD SUCCEEDED。
- 过程说明：`git stash` 因 `.claude/skills` 下的软链失败，改用 tar 备份 + `reset --hard` 快进；备份内容无独有信息（旧 ticket 副本已被分支版本取代，
  新文档已提交）。已安装的 1.0 App 与 9876 端口全程未动。

下一步：Lane A 的 P1 装机、Lane B 的 W1、Lane C 的 R1 / R2 都可以开了；启动命令见 `prompts-2026-09.md`。

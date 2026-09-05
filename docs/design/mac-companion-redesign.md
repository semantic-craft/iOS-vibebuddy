# Mac interface redesign — "Companion" (2026-09-06)

Outcome of a five-round grill-design session (prototype: Claude artifact
`78619df8-f99b-4ecd-9d5f-56d5131ab274`, final state). Each round showed five
contrasting variants of one question inside a live mock of every Mac panel; the
user picked one per round. This file records the decisions and the rules the
SwiftUI implementation follows. It is the reference for anyone touching the Mac
UI; the prototype is the visual truth where prose is ambiguous.

## Decisions

| Round | Question | Chosen | Rejected |
|---|---|---|---|
| 1 | Overall look | **Companion** — the cat is the protagonist; soft ground, large radii, pill controls, speech bubbles | Cupertino (native), Console, Instrument, Board |
| 2 | Panel structure | **C · grouped by state** — Needs you / Working / Done panels, no filter sidebar, cat small in the top bar | three-column filter, hero top bar, single inbox, cat room |
| 3 | Session row | **3 · summary-first** — tinted glyph circle, project as eyebrow, the agent's summary is the main line, activity in small caps | pill label, left stripe, single-line table, message bubble |
| 4 | Approval card | **Detail pane: 3 · request card with diff**; **Glance: 2 · two big keys** | current button group, cat asks, keyboard row |
| 5 | State summary | **Glance pill: 4 · only the needs-you count**; **everywhere else: 2 · the cat says one line** | glyph counts, stacked bar, labelled chips |

Settings keeps macOS grouped forms; only control tinting follows the palette.

## Tokens (`MacTheme.swift`)

Light / dark:

| Token | Light | Dark | Role |
|---|---|---|---|
| bg | #F5F7FC | #21242D | window ground |
| bg2 | #EDF1F9 | #282C37 | group panels, secondary ground |
| bg3 | #FFFFFF | #303542 | cards, rows |
| line | #E0E5F0 | #3B4152 | hairlines |
| ink | #2B3247 | #EEF0F6 | primary text |
| ink2 | #6C7590 | #A3AABD | secondary text |
| ink3 | #A8B0C4 | #6B7389 | tertiary text |
| accent | #5DA868 | #8AC37E | the cat's green; selection ring, primary buttons |
| error | #E8636B | same | |
| requiresInput | #F2A03D | same | |
| thinking | #5B8DEF | same | |
| completeUnread | #5DA868 | same | |
| idle | #B4BACB | same | |
| glance | #2B3247 | #151820 | notch card ground (not pure black) |

These soft status colours are for Companion surfaces only. The Kit's neon
`TaskStatusColorToken`s stay the source for the menu-bar badge, widgets and
`TaskStatusIndicator` where accessibility modes depend on them.

Type: system font, `.rounded` design (the prototype's Nunito). Sizes: eyebrow
12, body 13, row main 14 semibold, group title 14 heavy, detail title 26 heavy.
Monospace for paths, commands, diffs.

Radii: window/group panels 20, cards/rows 12, controls 999 (pills). Shadows are
one soft card shadow only; selection is a 2 pt accent ring.

## Copy rules

- Mood line (dropdown top, Glance expanded head, buddy bubble):
  `N things need you` / `1 thing needs you` / `All quiet — N working` /
  `All quiet`. Second line: `N working · N done · N idle` (zeros omitted).
- Glance pill: cat + an orange badge with the needs-you count (error + requires
  input). Zero → the word `All quiet`. Voice active → the existing
  Listening / Speaking badge replaces it.
- Group titles: `Needs you`, `Working`, `Done`, each with its count only.
- Row activity line: `ToolActivity.label` in small caps in the state colour;
  age and observation health follow in tertiary.
- Request card header: `<project> wants to <verb>` where verb comes from the
  tool: Edit → edit, Write → write, Bash → run, Read → read, else `use <tool>`.

## Panels

### Dashboard window
Top bar: cat (44 pt) + speech bubble (voice headline, provider badge, scope
line) + search field. Below: groups column (flexible) + detail column (360 pt).
Groups: three `bg2` panels with the title row; "Needs you" gets a warm tint
(10 % requiresInput over bg2). Rows are summary-first cards on `bg3`; the
selected row wears the accent ring. Empty groups are hidden; an empty snapshot
shows the existing `ContentUnavailableView` text.

Detail is one `bg3` card. Approval: request card (agent avatar CC/CX/GK, header,
path label, diff or command block, then `Approve ▾` split button whose menu
holds *Always allow this* and *Allow all this session*, `Deny` and
`Jump` as ghost buttons). Non-approval: title, state pill, summary, primary
`Jump to terminal`, `Recent output`, Notifications picker, model line.
Usage bars sit under the detail card.

Keyboard: ⌘F search, A / D approve / deny, ⏎ jump, ⌘1–5 / ⌘0 status filters
narrow the groups.

### Menu bar dropdown
Cat (34 pt) + mood line + second line; Open Dashboard / Show Glance buttons;
pairing line; then the same three state groups in compact summary-first rows
(needs-you rows keep the full row). Footer unchanged.

### Glance
Collapsed: cat + needs-you badge. Expanded: cat (40 pt) + mood line + ×; when
an approval is pending: `<project> wants to <verb>` label, path/command block,
two equal-width keys Approve / Deny, then an underlined link row
`Always · This session · Jump`; otherwise the three groups with small caps
headers and up to three rows each.

### Settings
Grouped forms as today. Toggles/pickers pick up the accent tint.

## iPhone and Apple Watch

The same rules carry to the other two surfaces; the artifact's iPhone and
Watch panels show them applied, and the implementation follows them. The
shared tokens, copy and controls live in `VibeBuddyKit/Sources/VibeBuddyKit/
Companion.swift` and `CompanionViews.swift` (palette, type, `CompanionCopy`,
`StateGroups`, `PillButtonStyle`, `StateGlyph`, `AgentAvatar`, `AgentBadge`,
`BucketTitle`, `SpeechBubble`, `SplitApproveButton`, `ApprovalBody`); the Mac's
`MacTheme` is a thin alias over them.

- **iPhone dashboard**: superseded by rounds 6–8 below — the message stream
  replaced the three panels on 2026-09-06.
- **Dynamic Island expanded / lock-screen Live Activity**: cat + mood line +
  second line; the leading session (project + state) underneath. Compact
  island: cat leading, needs-you badge trailing (working count in blue when
  quiet). The prototype's Approve / Deny keys on the island are *not*
  implemented: a Live Activity button needs an App Intent that can reach the
  Mac, which is its own feature.
- **Watch home**: cat + mood line + second line, then the needs-you sessions
  as rows, then the quota strips. **Watch approval**: `<project> wants to
  <verb>` label, the summary as the title, the path/command in a mono strip,
  Approve and Deny stacked full-width, `Always · This session` links below.
  Scrolling down shows Working and Done as small-caps lists.
- Palette, rounded type and radii are the Mac tokens; the Watch keeps its
  black ground and uses the status colours at full strength.

## iPhone rounds 6–8 (2026-09-06, artifact `79f0f9ce-1e20-4bac-98d8-93d69057cfe5`)

The phone got its own three rounds once the main branch had grown a task
composer ("Send instruction", new-task sheet, PR number, effort). Decisions:

| Round | Question | Chosen | Rejected |
|---|---|---|---|
| 6 | Arrangement | **D · message stream** — every session is a message from its agent, newest at the bottom, a real composer at the bottom | full cards, list + detail sheet, hero card + list, segmented tabs |
| 7 | Message unit | **1 · bubble + avatar** — agent avatar (CC/CX/GK) with the status dot at its corner; `project · agent · time` line; body `ACTIVITY — summary`; approval keys and question options inside the bubble | stripe bubble, card message, one-line expandable, cat narrates |
| 8 | Composer | **3 · reply to a message** — tapping Reply on a message puts a `Replying to <project> · <state>` banner above the composer; the message's state fixes the meaning (question → answer, working → instruction, done → continue); with no banner the composer means *new task* | target chip in the bar, chip row, mode segments, cat asks |

Rules that follow:

- **Meaning is never guessed from text.** The banner names the target and the
  meaning; the send button label repeats it (`Answer`, `Send instruction`,
  `Continue`, `New task`). Before a *new task* is sent, the target project and
  agent are shown once more (the existing new-task sheet stays for that).
- **Metadata lives behind the avatar.** Tapping the avatar or the `project ·
  agent · time` line opens the session detail (model, tokens, cost, PR,
  context bar, health, notifications, jump, recent output). The stream itself
  shows only the summary and what can be answered.
- **Order** is oldest → newest so the newest sits by the composer; the cat's
  bubble at the top says the mood line and the rest line, unchanged.
- **Approval / question / not-answerable** copy is the same as the Mac and the
  Watch; a request that cannot be answered from the phone ("You're at the
  Mac…") is a plain line inside the bubble, no keys.
- Dark and light follow the shared tokens; the cat in the header uses the icon
  geometry (rounded ears, green inner ears and belly).

Implemented on 2026-09-06 in `VibeBuddyApp/Sources/DashboardView.swift`:
`MessageRow` (bubble), `StreamComposer` (reply banner + field, the send button
names the meaning), `ReplyMeaning` (answer / instruction / continue / new
task, from the target's state; instructions only reach Codex sessions and the
banner says so otherwise), `SessionDetailSheet` (the numbers behind the
avatar, the attention picker, jump). A composer send with no target opens the
existing new-task sheet with the draft filled in.

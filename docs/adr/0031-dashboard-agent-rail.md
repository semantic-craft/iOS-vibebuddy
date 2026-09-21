# ADR-0031: The dashboard's first axis is the agent, not the project

- Status: accepted
- Date: 2026-09-21
- Amends: ADR-0024's "the sidebar is organized by project" and its middle
  session-list column; keeps its three-column shape, its one reader for both
  libraries and every reading rule. Amends ADR-0014's phone hub by putting the
  agent above its tiles. Keeps ADR-0017's tokens, flat register and "quota
  detail lives on Usage". Adds the terms *Agent rail*, *Agent column* and
  *Agent strip* to `CONTEXT.md`.

## Context

The sidebar's `PROJECTS` section listed every checkout a session had ever
reported: worktrees (`mac-dashboard-divider-resize-f34998`), scratchpads
(`probe-ws`, `review-647`), and the repos themselves — eleven entries and
scrolling on a normal day, most of them named by a hash the owner cannot read
at a glance. The list churns: a worktree appears when an agent starts in it and
leaves when the session ages out, so the row under the pointer moves between
one glance and the next.

The agents do not churn. Five of them report — Claude Code, Codex, Cursor,
Grok Build, Grok Bot — they are the same five tomorrow, each has a brand mark
that reads at 15 pt, and the owner's own question is usually "what is Claude
sitting on" or "who has allowance left", not "what happened in
`6de1cf`". The agent was already a filter, but it was a menu pill buried in the
list head, below the project rows that took the sidebar's whole scrolling area.

Two duplications came with that shape. The account-quota plinth at the sidebar's
foot listed the same five providers as a second, unrelated column of readings —
"can Grok take this?" was two surfaces away from "here is Grok". And the middle
list column repeated what a sidebar row could hold, at the cost of ~300 pt that
the reader wanted.

## Decision

1. **A rail of agents is the first column.** `DashboardAgentRail`, 48 pt, one
   tile per agent present in the current window (`DashboardAgentColumn.items`),
   **All agents** first. The chosen agent stays listed after its last session
   ages out, so tiles never shift under the pointer. Settings moves to its foot.
2. **The allowance is drawn around the agent.** Each tile is ringed by that
   provider's tightest window (`AgentQuotaReading`), All agents by the fleet's
   tightest; the column's head repeats it as a bar with its window name, share
   and reset. The sidebar's account-quota plinth is gone — Usage still holds
   every window, credit and spend (ADR-0017 §6).
3. **The sidebar is that agent's workspace.** Its head names the agent and its
   allowance, offers **New \<agent\> task**, keeps the voice rows and the five
   libraries, and under a `SESSIONS` heading carries a project pill, the search
   field, and the agent's live sessions grouped by **Needs you / Working /
   Unread results / Idle** (`DashboardAgentColumn.groups`). A group heading is
   the same filter ⌘1–⌘4 set; clicking it again clears it.
4. **The live library has no list column.** The sessions are in the agent
   column, so selecting one gives the reader the whole pane. `ResizableListSplit`
   stays for History and Favorites, which list records, not sessions.
5. **The libraries stay fleet-wide.** Inbox, Recap, History, Favorites and
   Usage count every agent even while the rail is on one of them: an Inbox that
   read "0 need you" because another agent's block was filtered out would hide
   work. Only the sessions under `SESSIONS` are scoped.
6. **A global route clears the rail.** The hotkey and "first pending task" mean
   every agent, so they return the rail to All agents before they walk the
   queue; a deep link to one session moves the rail to that session's agent
   rather than landing on a column that filters it out. ⌘1–⌘4 stay inside the
   chosen agent — the agent is a place now, not a filter to clear.
7. **Each library owns its project choice.** The column's pill narrows live
   sessions; History's own head carries the pill that narrows its index. They no
   longer track each other.
8. **The phone wears the same axis, laid on its side.** The iPhone's inbox hub
   carries an **agent strip** under its title (`PhoneAgentStrip`): the same
   entries as the rail, each a brand mark inside its allowance ring with the
   attention dot and the session count, **All** first. Choosing one scopes the
   hub under it — the mood line, First up, the four tiles and the project list
   (`InboxProjection(sessions:now:agent:)`) — and it carries into the list page
   the tiles open, into what *Read pending* speaks, and into **New task**,
   which starts in that agent's name. Back clears the bucket or project it
   opened, never the agent. The strip keeps counting every agent while the page
   under it is scoped, so "who else needs me" never leaves the screen; the
   phone has no room for a second column, so the four tiles stay the phone's
   attention grouping in place of the column's headings.
9. **The Watch gets the pairing, not the axis.** A rail of agent tiles on a
   40mm screen would push the alert card down to browse by tool, which is not
   what a wrist is for, and ADR-0021's order (what needs you, then what is
   running) is already the column's order. What the Watch was missing is the
   *pairing*: its allowance section listed providers by name, in the order the
   Mac happened to send them, away from the agents whose sessions fill the
   screen above. So its strips now carry the agent's own mark and short name,
   tightest allowance first (`tightestFirst()`), and a low reading follows the
   agent to where the decision is made — the alert card's identity line and the
   task header say "· 6% left" in the attention tint, and only below
   `QuotaReading.lowRemainingPercent`, because a healthy allowance beside an
   approval is noise.
10. **One roster, three platforms.** `AgentRoster` in the Kit computes the
   tallies the rail and the strip wear, `ProviderQuota.tightest` the allowance
   all three read, and `QuotaRing` draws it wherever it is a tile. The Mac
   keeps `DashboardAgentColumn.groups`, which only it has the height to show.

## Consequences

- The sidebar's scrolling area is a short, stable list of names instead of a
  long list of hashes, and "who is blocked" is legible from 48 pt of chrome.
- The window is rail (48) + column (168–320) + reader, so the reading gains
  roughly the old list column's width.
- Folding the column still leaves its own glyph strip beside the rail: two
  narrow columns, agents then libraries. Accepted — the strip is opt-in, and
  the rows in it are a different axis from the tiles beside them.
- A project is one menu away rather than one click, which is the cost of the
  churning list going away. The Inbox's project list is still a direct route to
  a checkout.
- `DashboardAgentColumn` is pure projection in `VibeBuddyMacCore` and tested
  there (`DashboardAgentColumnTests`); the rail and the column read it and never
  re-derive counts of their own.

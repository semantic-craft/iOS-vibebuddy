# Mac menu panel — command row and activity feed (2026-09-08)

Outcome of a six-round grill-design session (prototype: Claude artifact
[`e4f202b3-1cc4-48c4-bbd0-da84e23249fa`](https://claude.ai/code/artifact/e4f202b3-1cc4-48c4-bbd0-da84e23249fa),
final state). Each round showed five structurally different variants of one
question inside one live mock of the panel; the user picked one per round, then
settled four closing questions. This file records what was decided and the rules
the implementation follows. The prototype's last version carries the pixel
values and is the visual truth where prose is ambiguous.

> **Partly superseded (2026-09-12) by [ADR-0015](../adr/0015-menu-panel-flat-task-list.md).**
> The panel is now a flat, grouped list in Cursor's register: the cat left the
> command row for a mic, the list is the Companion's groups — `Needs you`, which
> never folds, over collapsible `Working`, `Done` and `Older` — instead of a
> pinned block over a rail-and-time-column feed, and rows are
> hairline-separated.
> Rounds 1 and 3 below still stand — the panel still opens on something you type
> into, and pet/field/badge are still one merged row. Rounds 2, 4, 5 and 6, the
> Anatomy rows marked *(ADR-0015)* and the behaviour they describe are history;
> the rest of this file is still the truth.

**This supersedes the menu-dropdown half of `mac-companion-redesign.md`** (its
round 2: state groups, 34pt cat, Open Dashboard / Show Glance buttons). The rest
of that file — palette, type, radii, copy rules, Dashboard, Glance, iPhone,
Watch — still stands, and this panel uses its tokens unchanged. *(2026-09-12:
the tokens themselves have since changed to Cursor's register under ADR-0017 —
neutral grounds, hairlines, Geist; the panel reads them through the same alias.)*

## The problem it answers

The user's words about the panel it replaces: not centred under its icon, and
"looks like something from ten years ago". Three concrete faults:

- the panel hung from the icon's **left edge**, so the icon looked stuck on its
  shoulder;
- the same fact was stated three times — a summary line, a filter menu, and an
  `N shown · M total` counter with an explanation under it;
- elements did not form a system: a jump and a toggle drawn as a symmetric pair
  of borderless text buttons, dividers across the panel, and the agent's own
  summary — the most valuable sentence in the product — truncated to fit beside
  a project name.

## Decisions

| Round | Question | Chosen | Notes |
|---|---|---|---|
| 1 | Overall form | **Command Bar** — the panel opens on something you type into | |
| 2 | Identity | **Buddy Bar** — the pet leads the command row rather than sitting in a header of its own | superseded by ADR-0015: the mic leads it |
| 3 | Head | **Merged** — pet, field and shortcut badge are one row, not a header plus a search bar | |
| 4 | The merged row | **Pet Carries It** — the pet's own badge is the global status light, so the row needs no separate state chip | superseded by ADR-0015: the light is the dot on the summary line. An "Action Strip" variant (approve/deny inside the panel) was rejected: it needs the approval channel and is its own feature |
| 5 | List | **Activity Feed** — one stream ordered by when each session last moved, with a time column and a rail | superseded by ADR-0015: three collapsible state groups, newest first inside each |
| 6 | Urgency | **Pinned** — error and waiting sessions are lifted out of the stream into a block at the top | superseded by ADR-0015: `Needs you` is the first group and the one that cannot be folded — the rejected "collapsed quiet section" stays rejected for it; `Working`, `Done` and `Older` collapse, and the folds reset every time the panel opens |

Closing decisions, same day:

1. **Filtering and local clearing are deleted outright.** Search is the only way
   to narrow the list. Filtering by state or agent, resetting filters, the
   `N shown · M total` line, the "summary includes all tasks" explanation, and
   "clear filtered Done and Idle from menu" are all gone, along with the empty
   state that clearing produced. This removed a whole round-identity mechanism
   whose only purpose was keeping clearing from hiding a newer round.
2. **The typing state gets a result band.** Choosing "Pet Carries It" in round 4
   left the input state with no summary at all, only the dot on the pet's head.
   A band under the command row fills that gap.
3. **The footer key legend becomes clickable.** Every exit — Dashboard, Glance,
   Settings, phone details, updates, quit — is a real control, so none of them
   is reachable only by shortcut.
4. **The two summary lines are merged and deduped.** They used to say the
   working count twice.

## Anatomy

Values from the prototype's spec block. Colours and type come from
`CompanionPalette` / `CompanionType` through the Mac's thin alias; this panel
adds no Mac-only colour.

| Part | Rules |
|---|---|
| Panel | 360pt wide, radius 14, ground `bg` *(ADR-0015: was `bg3`)*; the list scrolls past 320pt *(ADR-0015: was 250, for two-line rows)* |
| Command row | padding 13 / 10, gap 9; mic button 26pt on `bg3` (accent ground and white glyph while a conversation is live) *(ADR-0015: was the 26pt pet)*; placeholder 13.5 / `ink2`; `⌘K` badge 9.5 mono on `bg3` with a hairline, radius 5; hairline underneath |
| Status dot | 7pt circle leading the summary line *(ADR-0015: was 10pt on the pet's head)*; colour is the most urgent state present — error → needs you → working → complete → idle |
| Summary line | padding 2 / 13 / 8; dot, then mood clause 12.5 semibold `ink` and rest clause 11.5 `ink2` |
| Result band | typing only; ~24pt, ground `bg2`, 10.5 `ink2`; `<matched> of <total> · matching "<query>"`, with `<n> still need you` at the right end in the requires-input orange; 0.15s height change |
| Group head *(ADR-0015)* | title 12 medium `ink2`, count 11 medium `ink3`, chevron 9; padding 13 / 9 / 4; no ground, no uppercase — the rows' dots carry urgency |
| Row *(ADR-0015)* | dot lane 16 with a 7pt dot; padding 13 / 6; hover fills the whole row with `bg2`; hairline to the next row in the group, inset 29 |
| Row text *(ADR-0015)* | line one: title 12.5 medium `ink` (one line) and the age 9.5 mono `ink3` at the right; line two: `ToolActivity` in the state's colour then the agent's own sentence 11.5 `ink2`, one line |
| Footer | padding 6 / 9 / 7, ground `bg`, hairline above; three buttons 11pt `ink` with trailing shortcut hints 8.5 mono `ink3`; phone dot and `⋯` menu at the right |

Type ramp: 13.5 the field · 12.5 rows and the mood clause · 11.5 the rest
clause · 10 mono the time column · 9.5 the pinned heading and key badges.
Rounded system face for words, monospace for time and keys — both already in
the shared type scale. *(Since ADR-0017 the shared scale is Geist and Geist
Mono; the sizes are unchanged.)*

## Behaviour

- **The panel is centred under its icon.** Its centre line meets the status
  item's centre line, clamped 8pt inside the screen it is shown on, and clamped
  against the display the panel's *body* sits on (a panel's own screen flips to
  the display above the moment its top edge meets the menu bar). Height is not
  an input, so a panel that grows and shrinks cannot drift sideways.
- **The summary always reports the whole snapshot.** Typing narrows the list
  only; neither the summary nor the dot on the pet's head moves. This is why
  the band exists: `2 of 8` and `3 still need you` say plainly what the query
  put out of sight, so narrowing never looks like disappearing.
- **A session is in exactly one group** — `Needs you`, `Working` or `Done`, cut
  by presentation state through the Kit's `StateGroups`. A group with nothing in
  it is absent, not empty, and the panel shortens. Every group is recomputed
  from the query's results, and starting a search reopens all of them so a match
  cannot hide inside a fold. `Needs you` has no fold; the other three start each
  open of the panel the same way (`Older` closed, the rest open).
- **Ordering is by when the session last moved**, newest first, inside each group.
  Sessions sharing a timestamp keep the snapshot's own order, so two identical
  rounds cannot reshuffle rows.
- **Search matches the row's own title, its project, and the agent's summary**,
  case-insensitively; a query of only whitespace is no query.
- **Return jumps to the row the `↵ jump` badge marks** — the first row of the
  first group, so something waiting wins over something running, and a task that
  just finished is never the target while work is still going. The badge appears only while
  searching; with an empty field Return does nothing, because jumping somewhere
  from an empty field would be a guess.
- **The field takes the caret when the panel opens**, and each open starts from
  the whole snapshot. `⌘K` brings the caret back after clicking elsewhere.
- **The footer never wraps or grows taller.** As the panel narrows it sheds
  detail cheapest-first: the shortcut hints, then the phone's name, and only
  then the three labels. Tooltips carry the name and the shortcut in every
  form. At 360pt with the default Open-Dashboard Hyper chord this settles on
  icons, labels, and a phone dot.
- **Glance is a toggle, not a jump.** Its label swaps between `Glance` and
  `Hide Glance`, and it reserves the width of the longer label so flipping it
  cannot make the whole row re-fit itself.
- **Two empty states, worded differently**: nothing reporting ("No sessions
  reporting" / "Start a turn or repair hooks in Settings.") versus nothing
  matching ("No matches for …" / "Try another word, or ⌘K for commands."). Both
  centre a quiet 19pt glyph — `moon.zzz` or `magnifyingglass` *(ADR-0015: was
  the pet at 44pt)* — and hide the summary and the band.
- Motion respects "reduce motion" — the band's height change is dropped, not
  shortened.

## Where the implementation departs from the prototype

- **The summary sits above the scroller** rather than being sticky inside it.
  SwiftUI has no `position: sticky`; the visible result — an answer that stays
  put while a long list scrolls under it — is the same.
- **Shortcut hints show only when they fit.** The prototype drew `⌘D` / `⌘G`;
  the real Open-Dashboard default is a five-glyph Hyper chord, and three hints
  need about 75pt where roughly 43pt is free. Hints are the first thing the
  footer drops.
- **The phone button shows its dot only** at 360pt, for the same reason. The
  device name lives in its tooltip and its VoiceOver value.
- **The `↵ jump` badge is not in the user's rounds.** It was derived when the
  footer legend became controls and the badge lost its old home. It was kept
  only because Return was given a real meaning to match it.
- **The age is computed when the panel draws** (`now`, `44s`, `12m`, `3h`, `2d`)
  and does not tick on its own; sessions update often enough that the panel
  redraws anyway. *(ADR-0015: it rides at the end of the row's first line; there
  is no 52pt column.)*

## Testing seams

One projection carries almost all of this behaviour: sessions and a query in;
the non-empty groups in attention order, the whole-snapshot summary, matched and
total counts, and the empty state out. Tests assert order, group membership, the
summary's basis, count semantics, the three query outcomes, both empty states,
and the edges — equal timestamps, blank project names, a single-state snapshot,
a whitespace query. The panel's horizontal placement is a second pure seam, so
the two screen-edge cases that cannot be produced on a real menu bar (icon hard
against either edge, panel wider than the display) are covered by tests rather
than by hand. Copy lives in the Kit's shared summary functions and is tested
there.

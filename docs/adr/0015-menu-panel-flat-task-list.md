# The menu panel is a flat, grouped task list

**Status:** Accepted (2026-09-12) — amends ADR-0007 and supersedes four rounds
of `docs/design/mac-menu-command-bar.md`.

## Context

The menu-bar panel was settled in a six-round grill-design session
(`docs/design/mac-menu-command-bar.md`, 2026-09-08): the pet leads a command row
and carries the global status light (rounds 2 and 4), the list is one
time-ordered activity feed with a 52pt time column and a rail (round 5), and the
sessions that need a person are lifted into a tinted block under an uppercase,
letter-spaced `NEEDS YOU` heading (round 6).

The product has since moved into Cursor's visual register — neutral grounds,
Geist, hairlines instead of shadows (`CompanionPalette` / `CompanionType` in the
Kit). Against that, the panel still read as an older, louder product: a cartoon
face over a tinted block with a timeline drawn down its gutter. The owner asked
for the panel to look like Cursor's iOS home screen at panel size.

## Decision

**The panel is a flat, grouped list**, in the chrome of `MenuChrome.swift`:
`MenuCircleButton`, `MenuSectionHeader`, `MenuHairline`. Same Kit tokens as
every other surface; the sizes are the panel's own.

**The cat leaves the command row.** The mic takes its place — a 26pt circle
button whose glyph follows the voice phase — and the panel's status light
becomes the dot that leads the summary line, still the most urgent state in the
whole snapshot. The menu-bar **mark** above the panel is still the cat.

**The list is the Companion's three groups, not a stream.** `MenuFeed` projects
the snapshot through the Kit's `StateGroups` into `Needs you` / `Working` /
`Done`, newest first inside each, and exposes them as `sections`; `pinned` and
`feed` are gone. Each group is collapsible from its own head (title, count,
chevron, quiet ink), an absent group draws no head, and starting a search
reopens every group so a match can never hide inside a fold.

**Rows are flat.** A status dot, the title and how long ago it moved on the
first line; what the agent is doing (`ToolActivity`, in the state's colour) and
its own sentence on the second; a hairline to the next row, inset past the dot.
The 52pt time column, the rail and the tinted block are gone, and hover fills
the whole row instead of a card. The panel's ground is `bg`, its controls `bg3`,
its hover `bg2`.

## Consequences

- **Supersedes rounds 2, 4, 5 and 6 of `mac-menu-command-bar.md`.** Rounds 1 and
  3 stand: the panel still opens on something you type into, and the row is
  still merged rather than a header plus a search bar. Search is still the only
  way to narrow the list — this brings back grouping, not filtering.
- **Amends ADR-0007**: the cat no longer draws in the menu panel. It keeps the
  menu-bar mark, the Glance, the Mac dashboard, the Live Activity, the Watch and
  the app icon, and still starts the voice companion from the Mac's own pet — in
  the panel that entry point is the mic.
- **Return now jumps to the first row of the first group**, so a task that just
  finished is never the target while something is still running. `topResult`
  follows the order the panel draws.
- Collapse state is in memory for the life of the panel and keyed by the group's
  kind, not its heading, so it survives snapshots and a change of language.
- The iPhone's own list is untouched by this decision. If the phone takes the
  same three groups later, `StateGroups` is already the shared rule.

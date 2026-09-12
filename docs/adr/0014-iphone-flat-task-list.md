# The iPhone dashboard is a flat task list; the pet leaves it

**Status:** Accepted (2026-09-12) — amends ADR-0007 for one surface.

## Context

The iPhone dashboard was the Companion header (a 64 pt cat plus a speech
bubble), two rows of filter chips, a filter link, and then chat-style bubbles
in one flat, oldest-first stream. On a real snapshot that spends roughly the
top third of the screen before the first task, and the stream itself is
undifferentiated: fifteen finished rows read exactly like the one that is
waiting for an answer.

Two failures came from the same screenshot the owner sent:

1. **Density and register.** The rounded face, black weights and shadowed
   bubbles read as a toy next to the agent tools the app sits beside. The owner
   asked for Cursor's iOS app as the reference — a neutral page, plain grotesk
   type, hairlines, collapsible groups, round glyph buttons, one composer.
2. **Staleness.** The Mac's reducer only evicts a `needsResponse` session
   (2 h). `done` sessions live as long as the daemon does, so rows five days old
   sat at the top of the phone's list and were counted in its summary line.

## Decision

**One flat visual language on the iPhone**, spending the Companion tokens the
Kit now carries (neutral grounds, Geist, hairlines instead of shadows) on a
denser phone layout, in `PhoneChrome.swift`: round glyph buttons over the page,
`PhoneSectionHeader` for collapsible groups, `PhoneButtonStyle` rounded rects in
place of pills, `PhoneDivider` between rows, `PhoneSheetHeader` (round close
button, centred title) on every sheet.

**The pet leaves the iPhone dashboard.** `BuddyView` and the iOS `PetFace` are
deleted. The page title is the paired Mac (status dot, name, connection menu)
over one line of the same copy the cat spoke — `CompanionCopy.moodLine` +
`restLine`. **The mic in the composer is the voice companion's entry point**,
where the cat's tap used to be; its state also drives the glyph, and `VoiceStrip`
still carries the transcript.

**The list is grouped and collapsible**, not one stream: by status (Needs you /
Working / Done) by default, optionally by project or agent, newest first.
`DashboardCustomizeSheet` — grouping, the four filters, and the recency switch —
replaces the chip rows and the old filter form.

**A 24-hour recency window** (`SessionRecency`) decides what the list shows: a
session that is `needsResponse` is always current, however old; everything else
must have moved inside `SessionRecency.window`. The window is presentation only —
`DashboardStore.allSessions` stays complete, so deep links, answers, acknowledgements
and the Buddy scope still resolve a session the list is hiding. The list offers the
hidden rows back ("Show N older") and Customize has the same switch.

## Consequences

- **Amends ADR-0007** (the cat on every surface): the iPhone *dashboard* no
  longer draws it. The cat stays everywhere else it was — the Live Activity
  (`ActivityCat`), the Watch (`WatchCat`), the Mac glance and dashboard, the
  menu-bar mark and the app icon — so the character is still the product's face;
  it just no longer opens the phone's list. Zero bundled artwork still holds.
- **CONTEXT's "tap the pet to talk" is now phone-specific copy**: on iOS it is
  "tap the mic". The glossary is updated with the surface.
- **The widget, Live Activity and Watch relay keep the Mac's full session set.**
  The window is applied in the phone's list, not in `DashboardStore.install`, so
  nothing downstream silently loses a session it is holding a notification for.
  If the same staleness shows up on those surfaces it is a separate decision.
- The phone shows fewer rows than the Mac's menu-bar panel by design. A person
  looking for older work reaches it through Customize, not by scrolling.

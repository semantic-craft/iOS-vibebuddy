# Accessibility audit, September 2026 (G-4)

The first accessibility pass over the Mac menu-bar app and dashboard, the iPhone
app with its widgets and Live Activity, and the Watch app. The standing checklist
that came out of it is `docs/design/accessibility-checklist.md`.

Method: a code audit of every SwiftUI surface against the HIG, then Apple's own
audit (`performAccessibilityAudit`, `tools/a11y-audit/`) and the element tree on the
iPhone and Watch simulators with the demo data, at the default text size and at
the largest accessibility size (AX5), before and after the fixes. On the Mac, the
demo build of main and of the branch each ran as an isolated copy (port 9877, not
the installed app) and its accessibility tree was dumped by pid
(`tools/a11y-audit/axdump.swift`). Contrast was computed from the palette's hex
values (translucent tokens composited onto their ground first). Evidence was
captured on 2026-09-25 against main `6236e188`; the raw runs (audit JSON, element
trees, screenshots, before/after pairs) are in
`~/Projects/_shared-work/iOS-vibebuddy/g4-a11y-2026-09-25/`.

## What was wrong, and what changed

Severity: **high** blocks a VoiceOver, large-text or Reduce Motion user from a core
flow (approve, deny, answer, see what needs them); **medium** makes it hard;
**low** is polish.

### Watch

| # | Sev | Finding | Fix | Evidence |
|---|---|---|---|---|
| W1 | high | The request card was one combined element. VoiceOver saw a single 346 pt "button" labelled with the whole card, ending in "…, Approve"; on a question card it ended in the first quick answer ("…, Yes, go ahead."). Approve, Deny and the answers were only reachable through the Actions rotor, and a double-tap on the card risked activating the first of them. | The card `.contain`s its elements; only the header and the meta line combine. | Element tree before: `Button {183×346} label: 'ios-vibebuddy wants to run, 38s, Build the Watch app, xcodebuild …, Claude · ios-vibebuddy, Approve'`. After: `StaticText 'ios-vibebuddy wants to run, 38s'`, …, `Button 'Approve'`, `Button 'Deny'`, no wrapping button. |
| W2 | high | At large text sizes the question (3 lines), the command under approval (4 lines), the question-walk text (4 lines) and each answer option (2 lines, scaled to 70 %) were cut: the wearer could approve or pick something they had not read in full. | M-07 (#313, merged during this pass) shows questions, commands and options whole with Crown scrolling; this pass adds the same at accessibility sizes for the card's header, fallback title and meta line, and for the confirmation captions. | AX5 tree on this branch before the merge: the command's frame grows from 68 to 84.5 pt (whole command shown). |
| W3 | medium | "Sending…", "Your Mac has it", "Not sent: …" appeared silently under a key VoiceOver had moved away from. | Status sentences are announced when they change (approve, answer, stop). | Code. |
| W4 | medium | Multi-select picks were a check-mark glyph only. | `.isSelected` on the option; the glyph is hidden. | Code. |
| W5 | medium | The review page's Send key was white on the dark mint: 2.06:1. | The shared filled style with the `onAccent` label: 9.09:1. | Computed. |
| W6 | medium | Approve, Deny and Stop were `lineLimit(1)` scaled to 80 %. | Two lines. | Code. |
| W7 | medium | The followed-task complication drew its status word in the neon token: thinking `#304FFE` on black is 3.68:1. | `CompanionPalette.status`: 7.80:1. | Computed. |
| W8 | low | Quota strip columns were fixed 38 / 58 / 32 pt; "100%" clipped at large sizes. | `@ScaledMetric` columns. | Code. |
| W9 | low | One-line rows were ~27 pt tall; the idle dot was 2.86:1 on black; banner and footer glyphs were read as symbol names. | Rows ≥ 38 pt; idle dot 3.09:1; glyphs hidden. | Computed / code. |

Reduce Motion: the Watch has no looping or moving animation; nothing to change.

### iPhone, widgets, Live Activity

| # | Sev | Finding | Fix | Evidence |
|---|---|---|---|---|
| P1 | high | Question-card picks were a glyph only (no `.isSelected`), and a single-choice option sent on tap with no warning. | `.isSelected`; hint "Sends this answer". | Code. |
| P2 | high | The only word on whether an approve, deny or answer got through was a 2.5 s toast that VoiceOver never heard. | Announced; stays 8 s while VoiceOver runs. | Code. |
| P3 | high | In the reader, Approve/Deny lived inside the approval's height-capped scroll: at AX sizes the command pushed them below its fold. | Keys pinned under the scroll, stacking when they no longer fit side by side; hint names the command. | AX5 screenshot pair (reader). |
| P4 | high | At AX5 "First up docs-review" collapsed to "First do…", the bucket tiles and the agent strip to "Cl…", "Co…", "Gr…". | "First up" stacks and wraps; tiles go to one column; the agent strip caps at xxxLarge and offers the Large Content Viewer, like the system tab bar. | AX5 audit, home: textClipped 6 → 0; screenshot pair. |
| P5 | high | Dynamic Island / Live Activity Approve key: white on the dark mint, 2.06:1; the compact count white on amber, 1.83:1. | `onAccent`: 9.09:1 and 10.23:1. | Computed. |
| P6 | medium | The lock-screen Live Activity sits on the dark glance in both appearances, but in light mode its status words resolved light: red 2.98:1, amber 3.64:1, blue 3.66:1. | The view forces the dark colour scheme: 4.72, 10.06, 6.84:1. | Computed. |
| P7 | medium | No Reduce Motion handling anywhere in the app: list reorders slide, toasts and the reply card slide in, scrolls animate. | Fades or cuts under Reduce Motion. | Code. |
| P8 | medium | The read-aloud and voice strips opened the voice page through `onTapGesture` + `.isButton` on a container, so the trait landed on every line (or nowhere); the phase icon was read as "ellipsis"/"waveform". | One button element per strip with the call phase as its value; glyphs hidden. | Tree. A regression the audit caught mid-pass (the strip's text became a 14 pt button) was fixed with a 44 pt minimum. |
| P9 | medium | Task rows put the state word last on a one-line meta line, so at AX sizes it was cut first. | At AX sizes: title up to 3 lines, then state, detail and project one per line. | Code / screenshots. |
| P10 | medium | Keys drew at 27–40 pt with the same touch target; the held-decision ✕ was ~20 pt, the reply ✕ 26 pt, Redial 25 pt. | Invisible slop to 44 pt (`PhoneButtonStyle`), 44 pt ✕ targets, Redial 44 pt. | Code. |
| P11 | medium | Section headers said expanded/collapsed only as a hint; there were no headings for the rotor. | `.accessibilityValue` + `.isHeader` (Kit `CompanionSectionHeader`, Inbox title, Projects, reader title). | Code. |
| P12 | low | The circular lock-screen widget read "CL, 42%". | "Claude, 42% left". | Code. |

### Mac

| # | Sev | Finding | Fix | Evidence |
|---|---|---|---|---|
| M1 | high | While the notch glance is on screen, a cue becomes a glance card instead of a system notification; the card is never announced and folds away after 2.5–8 s. A VoiceOver user was never told an agent was waiting. | With VoiceOver running, cues go out as system notifications (read by VoiceOver, kept in Notification Center). The card's Approve / Deny also name the command. | Code (`presentGlanceCard`). Tree: glance card `Button 'Approve'` → `Button 'Approve' help='src/reminders.ts'`. |
| M2 | high | Question-card picks had no `.isSelected`; single-choice sent on click unannounced. | As P1. | Code. |
| M3 | medium | White on the dark mint Approve key (dashboard `SplitApproveButton`, glance card keys): 2.06–2.55:1; the glance's needs-you badge white on amber 1.83:1. | `onAccent` (Kit, shared with the phone). | Computed. |
| M4 | medium | The glance panel followed the system appearance although its ground is always black: light-mode status reds were 2.98:1 there. | Panel appearance fixed to dark. | Computed. |
| M5 | medium | Island shape changes used a spring and a scale transition; the voice badge looped a variable-colour effect; the card countdown ran at 20 fps. None read Reduce Motion. | Short fade, no scale, effect off, 1 fps. | Code. |
| M6 | low | Nine invisible `Button("")` shortcut carriers (⌘N, ⌘1–4, ⌘0, ⌘F, ⏎, and the `a` = Approve carrier). SwiftUI already left them out of the tree in the demo dashboard, so this is defensive. | Explicitly hidden from accessibility; the shortcuts still work. | Tree: absent before and after. |
| M7 | medium | The glance could only be expanded by hover or click; the announcement controls, the ✕ and the voice toggle had no names ("Toggle voice companion"). | "Expand glance" action; labels that say the action; 20 pt targets. | Code. |
| M8 | medium | Sidebar rows carried the state only in a 6 pt dot; the agent header was one button whose value was the quota, with the real quota button reduced to a hidden custom action. | State in the row's value; the header is a heading, the quota its own button. | Tree before: `Button 'docs-review' value='Claude · docs-review'`, `Button 'All agents' value='Other Models 8% left…' actions=…Name:Account quota`. After: `value='Requires input, Claude · docs-review'`; `Heading 'All agents' value='8 sessions'` + `Button 'Account quota'`. |
| M9 | medium | Usage page warnings in `Color.orange`: 2.14:1 on the light ground. | Status amber: 4.93:1. | Computed. |
| M10 | medium | Hairlines were 1.2–1.3:1 and are the only edge of ghost keys (Deny) and chips; Increase Contrast changed nothing. | Translucent tokens close half their gap to opaque under Increase Contrast (hairline ~4:1 light, 5.5:1 dark). Applies on iPhone too. | Computed. |
| M11 | low | 8–9 pt information text (glance Small preset, sidebar times and resets, read-aloud status). | ≥ 10 pt. | Code. |

The pet (`BuddyCatFace`) was already hidden from VoiceOver everywhere and still
under Reduce Motion (`BuddyCatMotion.frame(reduceMotion:)`, `PetFace` pauses its
clock); its state is spoken through the voice badge, the glance count and the
menu-bar item. `TaskStatusIndicator` already honoured Reduce Motion, Differentiate
Without Color and Increase Contrast; `StatusDot` now does the second too. Agent
avatars and `StateGlyph` are now single labelled elements.

## Audit numbers (iPhone)

`performAccessibilityAudit`, demo data, iPhone 17 Pro simulator (iOS 27).

| Run | Before | After |
|---|---|---|
| Default size, 8 pages | 64 issues | 63 |
| AX5, home | textClipped 6 | 0 (after the second round) |
| AX5, read-aloud page | textClipped 6 | 1 |
| AX5, reader on an approval | textClipped 3 | 1 |

The totals barely move because most default-size `textClipped` flags are a false
positive from Geist's line metrics on single-line labels (the screenshots show
them whole), and capping the agent strip at xxxLarge is reported as
`dynamicType` by design. What changed is which text is cut: after the pass, no
text the user decides on is truncated at AX5. Remaining contrast flags are the
demo's brand marks on their 14 % wash (non-text, labelled) and ink3 on the
selected-row wash (4.26:1, see below).

Watch audit: clean before and after except one 50 × 16 pt agent label on the task
detail page (not a control); the Watch's real defects were in the element tree
(W1), which the audit does not judge.

## Not changed, on purpose or for later

- **Single-key shortcuts `a` / `d`** on the Mac (WCAG 2.1.4). They are the owner's
  requested workflow and only fire in the dashboard's key window; kept.
- **ink3 on the selected sidebar row's accent wash** is 4.26:1 (below 4.5). A token
  change touches every surface; left for a design pass.
- **Brand marks on their own 14 % wash** (Claude 2.64–2.71:1): logos, always next
  to a spoken name.
- Low-severity polish from the audit not taken in this pass: narrow duration
  formats ("4m") in VoiceOver strings, focus placement after the Watch question
  walk auto-advances, iPhone settings fields that take their spoken label from the
  placeholder, the read-aloud queue's "now reading" state on the voice page.

## Not verified here

- **VoiceOver on a real device.** The tree, the audit and the code are checked;
  nobody listened to the Watch card or the island with VoiceOver on hardware.
- **Mac Reduce Motion and Increase Contrast** were checked in code, not by switching
  the owner's own accessibility settings. The glance panel cannot be screen-captured
  from the isolated copy, so its contrast is the computed values above.

# ADR-0024: The dashboard's right column is a session reader

- Status: accepted
- Date: 2026-09-13
- Amends: ADR-0020's detail order (*goal, progress/result, decision, actions,
  then expandable evidence* → head, jumps, body, dock) and its Recent output
  pane; keeps ADR-0020's state, result identity and reading semantics, ADR-0017's
  tokens and flat register, ADR-0019's session keys and transcript reading.
  Adds the terms *Session reader* and *Reader source* to `CONTEXT.md`.

## Context

The owner reads their agents from the dashboard, not from the terminal. Until
now selecting a live session showed a detail card — a 20pt goal, a tinted
status capsule, progress, the decision, an Actions row, the whole
Notifications chip row with its explanation, model and observation lines, a
folded Activity group — and under all of that a *Recent output* pane limited
to twelve entries of 600 characters, telling the reader to open History for
the full conversation. The real reader (Markdown, code copy, folded tools,
paging) lived in the History library, with its own project choice and no
agent filter on the live list. The largest area of the window repeated what
the list row already said and made the conversation two steps away.

The owner asked for Wake's shape — three stable columns and a reading pane
where the body dominates — with two differences: the agent filter sits in the
middle column, and the sidebar is organized by project. Wake's *conversation
source* rule was adopted as well: the agent's own local transcript file is the
only body; an index only lists and searches; the open transcript is parsed on
demand and re-read when its file changes.

## Decision

1. **One reader for both libraries.** `SessionReaderPane` shows a live
   session and a history record alike: a two-line head (title; agent · project
   · state dot and word · model · observation · body source) with every control
   as a glyph in its top-right corner, the body, and a dock. `SessionReaderView` renders the rows for both. The
   detail card, the Recent output pane and the Recent output sheet are gone.
2. **Body source by exact identity.** A live session's id is the agent's
   native session id; its transcript key is that id under the agent's key name
   (`SessionReaderSource`). The body is read through
   `SessionHistoryRepository.readTranscript(key:)` — fresh from the source
   file when the index is stale, located by native id when the index has no
   row yet. Agents without a transcript reader fall back to the daemon's
   bounded recent output, labelled as an excerpt. Titles never match records.
3. **The open transcript is watched.** One `DispatchSource` on the selected
   transcript file, settled over 800 ms, re-reads the body; the live session's
   turn boundaries (status, activeTool, completionID) are the fallback trigger.
   Results are written back only for the subject still selected.
4. **Opens on the newest page.** The body shows the last thirty rows and
   walks backwards on request. New rows follow the reader only at the bottom;
   otherwise a pill counts them. A search hit is revealed at the top.
5. **The decision is docked.** A pending approval or question, and the
   composer when the session accepts a steer or a new turn, sit in a dock
   under the body, never in a menu. History-only records have no dock.
6. **Controls in the head's top-right, as glyphs.** The jump (accent), a
   Conversation / Activity / Changes switch, the notification bell (the
   attention picker in a menu), the star (when a record exists) and a ··· menu
   (read state, replay, summary, pin, archive, export, source, resume command,
   refresh). Every glyph carries a tooltip and an accessibility label; no
   control in the head is a text button, so the head stays two lines wide at
   340pt. Activity is disabled for
   a record with no live session; Changes follows the project directory, live
   or not, because a workspace diff is read by path.
7. **The jump names where it lands.** One glyph, shown only when the session
   has a target; its tooltip is resolved per host (`JumpDestination`): *Jump
   to terminal* for a pane in a terminal emulator, *Jump to Claude* / *Cursor*
   / *VS Code* when only the hosting app can be raised, *Jump to ChatGPT* for a
   Codex Desktop thread, *Open Grok Bot*. ⏎ on the dashboard does the same.
   *Copy resume command* and *Show source* live in the ··· menu; the approval
   card in the dock offers Approve / Deny only. The outcome
   copy (`JumpOutcomeCopy`) reports what was actually raised.
8. **Semantics carried forward from ADR-0020, verbatim in effect.** A
   transcript proves nothing about live state; the head says *No live status*
   when the daemon has none. A result belongs to one source, session and
   completion, shown as a card at the end of the transcript from the daemon's
   `completionBody`; only that card's foreground visibility, in the key
   dashboard window with the task viewed, confirms a read. The transcript's
   own last message, even with the same words, never does. Selecting a row,
   loading a body, scrolling or jumping is not a read. Reading a transcript
   grants no ability to send to, control or resume the session.
9. **The middle column filters by agent** with the same menu the History
   list has; the sidebar's project choice follows across libraries when the
   names match unambiguously. Live and history lists are not merged.

## Consequences

- ADR-0020's Recent output pane and detail order are superseded on the Mac;
  the phone's recent-output pane is unchanged.
- The Kit's `WorkspaceChangesView` gains an `embedded` mode for the Changes
  view; `DashboardSessionList` gains an agent parameter; `HistoryMessageRow`
  gains a standalone factory for the excerpt fallback.
- A transcript is re-parsed in full when its file changes; the parser bounds
  each message, and the repository's revision cache skips unchanged files.
  Incremental tailing is deferred.
- Acceptance is by real transcripts in an isolated instance; demo data seeds
  only the live rows and proves nothing about reading.

## Integration with the current dashboard (2026-09-14)

The reader replaces the live detail tool shelf with its Conversation, Activity
and Changes views. The existing Inbox counts, scoped Next pending navigation,
current/older filters, retained live selection after reading, and per-session
composer drafts remain. Project identity follows the full checkout path; a
basename is used only for legacy rows with one unambiguous history match.
Only the conversation tab counts as viewing the task for notification suppression.
Manual read toggles in the head and result card share the same completion guard.

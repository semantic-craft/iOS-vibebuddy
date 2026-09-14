# The Mac is the board, the voice and the progress desk for autonomous tasks

**Status:** Accepted (2026-09-13). Implements the owner's subsequent implementation
request for `.scratch/yolo-first-attention/PRD.md`, Revision 2.

## Context

The owner's everyday agents usually run autonomously. The desktop must make
progress and results readable across tasks, announce trustworthy results, and
help the person move to the next task. An approval-only centre and the earlier
vision Q6 infrastructure-only priority do not serve that use.

0018 belongs to Cursor cloud agents. 0019 is reserved by another session's
agent/MCP/CLI draft in the shared checkout. 0020 was the smallest free number
when this decision was recorded; neither existing document is replaced.

## Decision

- Keep the three lifecycle states and `SessionCurrency`. The presentation groups
  are Needs you / Working / Done. Needs you ranks questions and plan decisions,
  then approvals, then **confirmed terminal failure**. A tool error followed by
  recovery stays Working. Observation loss supplies no terminal outcome.
- A row leads with task identity and activity/result. Detail order is goal,
  progress/result, decision, actions, then expandable evidence. An approval never
  replaces the complete detail or hides the Glance task list. Completion text
  belongs to the exact source, session and round; missing results stay unavailable.
- Unread means not yet read, never reviewed, verified or accepted. Successful
  foreground result reading or an explicit read action confirms that exact round.
  Automatic reading confirmation is available on macOS 15+ and iOS 18+ only
  after the actual result body enters the viewport and its task is actively
  viewed in the foreground. Loading offscreen text or retaining a selection
  does not qualify. Older OS versions retain explicit read buttons. Marking the
  same result unread while it remains open does not immediately confirm it again.
  Jump, lists, notifications and audio do not. Mark unread restores only the
  reading marker. Once acknowledged, the round's automatic reminder budget stays
  retired, including across daemon restart. A stale read cannot clear a new round.
- Pending navigation visits Needs you, then unread Done. The menu summary names
  both counts. Its badge counts their disjoint union and defaults on when no
  explicit preference exists; a saved false remains false.
- Permission mode is descriptive evidence. Claude `auto` is distinct from
  bypass; Codex approval policy and sandbox remain separate raw values; Cursor
  is unknown. Actual waits and request capabilities govern decisions and cues.
  Do not add an Approvals navigation section or infer privileges from silence.
- Announcements reuse Completion notice, Read aloud and completion identities.
  They are opt-in, bounded to ten items including the current playback, deduplicated, sequential, and
  checked against live state before playback. A blocker is next without cutting
  off a playing sentence. Pause, skip and replay never acknowledge a result.
  Real-time voice takes priority. Overflow retains newer entries and leaves text
  results available. Failure is visible, with no automatic retry loop.
- Viewing the actual task suppresses completion banners and cue sounds. Speech
  has its own viewing-silence preference, default off. Quiet, categories and
  attention still apply. Internal child completion does not announce parent
  completion. Agent claims remain attributed rather than independent validation.
- Phase two exposes bounded observed tool records and read-only workspace diff.
  Intent is not success, missing results say unconfirmed, repeated paths are
  deduplicated, cumulative edits are not net Git change. Git scope and baseline
  are explicit: uncommitted compares tracked working-tree content with HEAD
  (including staged changes), staged compares the index with HEAD, and branch
  compares HEAD with the selected baseline’s merge base. A clean workspace never silently switches to branch comparison.
  Workspace changes are not attributable to one session or its author.

## Consequences

This is a **new decision** revising ADR-0011's Glance approval placement and
ADR-0015's information order and failed-task grouping; those historical ADRs did
not already promise these behaviours. ADR-0010's permission persistence and
ADR-0012's notification identities and cross-device receipts remain authoritative.
ADR-0017's Cursor tokens and flat visual language remain in force. Watch layout
and takeover rules are unchanged.

The activity ledger adds bounded command/path persistence in an owner-only
sidecar beside the lifecycle journal: at most 50 records per session, 250 sessions,
seven days and 8,000,000 bytes, with only the latest 20 records in a snapshot. This is
new local evidence storage, not a claim that the original privacy-minimized
lifecycle journal already stored command text. Full tool output, reasoning and
prompts are not copied into the ledger. Clearing sessions/history clears its
corresponding records. Coverage is partial and is always labelled.

Dangerous-command banners, diff comments, PR/CI management, cross-task merged
spoken briefings and a Watch redesign are deferred or removed. Implementation,
automated evidence, isolated runtime evidence and human acceptance remain separate;
local ticket 12 is owned by the human. This ADR authorizes no installation, push,
deployment or cross-machine synchronization.

## Amendment: shared pending navigation on iPhone (2026-09-13)

The mobile/Watch implementation extends the original phase's Watch boundary as
recorded in ADR-0021's amendment. The iPhone's **Next pending** follows the owner's
chosen current list filters (including whether Older is shown), states that scope,
and shares candidate ordering and tour progression with the Mac. The Mac's detail
footer now also retains bucket, project, query and Older scope; the named global
Next pending shortcut opens a global tour. Equal input timestamps preserve input order;
reading a result removes it from pending without moving the page or restarting the
tour at a skipped wait. Navigation is not a read or a control action.

## Amendment: explicit Mac Read pending (2026-09-14)

Inbox can read the global current pending queue with automatic Announcement
turned off. It shares the existing bounded ten-item execution queue, deduped
by source, Session and round or wait identity, with automatic cues. Each item
is checked again before playback; stale results never become new-round speech.
Voice and reading exposes current and queued tasks, pause, skip, explicit
previous-result replay, stop and settings. None of these controls acknowledges
a result. Closing the panel stops nothing. A live conversation pauses manual
reading, which remains paused after the call until an explicit resume. Mac
voice, summary and read-aloud provider choices stay independent as configured;
there is no imported phone system-speech fallback.

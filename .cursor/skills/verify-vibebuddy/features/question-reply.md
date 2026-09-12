# Question reply

When a Session is `needsResponse` with `waitKind=question` and an answerable `pendingQuestion`, the user replies from the iPhone **Reply** composer, a question card's options, the Mac card, or Watch quick answers. Claude's `AskUserQuestion` is held on `POST /approval`; the answer returns in the hook's `updatedInput`.

## Sub-features

- `q-hold` holds Claude `AskUserQuestion` on the approval route and surfaces `pendingQuestion`.
- `q-text` sends a free-text `POST /answer` `{"sessionId","answer"}` (older clients; fills the first question).
- `q-options` sends structured `answers` keyed by item id, matching the card buttons.
- `q-expired` an `expectedQuestionId` that no longer matches returns `409` and does not become a steer.
- `q-readonly` a present-at-Mac wait is `answerable: false`; the user answers on the Mac prompt.

## How to get to it (user POV)

- On iPhone: open the waiting row, tap **Reply**, type or tap an option, submit.
- On Mac Dashboard / Glance: the question card with the same options.
- On Watch: quick answers only for a single-string wait.
- Claude Code raises this via the approval hook when the tool is `AskUserQuestion`. Codex questions arrive through the connected app-server (`/answer` with that session's question id).

## Driving it with control-vibebuddy

Preconditions:

- Isolated daemon, `doctor` passed. Headless presence is false, so the card stays answerable.
- No session `vb-verify-askq` already holding a question.
- Decide within the approval timeout (~25s, same hold as permissions).

- **Hold AskUserQuestion.** Run `control-vibebuddy approval --json '{"hook_event_name":"PreToolUse","session_id":"vb-verify-askq","cwd":"/tmp/verify-docs-review","tool_name":"AskUserQuestion","tool_use_id":"toolu_verify","tool_input":{"questions":[{"question":"Which revision style should I use?","header":"Style","multiSelect":false,"options":[{"label":"Short","description":"Brief"},{"label":"Long","description":"Full"}]}]}}'`.
- **See the card.** Poll `control-vibebuddy snapshot` until `vb-verify-askq` has `status=needsResponse`, `waitKind=question`, and `pendingQuestion.prompt` equal to `Which revision style should I use?`. Record `pendingQuestion.id`.
- **Reply.** Run `control-vibebuddy answer --session-id vb-verify-askq --text 'Short' --question-id '<pendingQuestion.id>'`. HTTP 200.
- **Confirm.** Snapshot: `pendingQuestion` is absent and `status=working`. The held approval response body includes `permissionDecision` `allow` and `updatedInput.answers` mapping `Which revision style should I use?` to `Short`.
- **Expired identity.** After the card is gone, run `control-vibebuddy answer --session-id vb-verify-askq --text 'too late' --question-id '<old id>'`. HTTP `409`. The session does not gain a new wait.
- **Proof.** Run `control-vibebuddy evidence --label question-reply`. Keep snapshot-with-question and snapshot-after-answer. Do not treat a Notification-only row (`waitKind=question` but no `pendingQuestion`) as this feature — that path is dashboard visibility only (`dash-need-question`).

## Gotchas

- AskUserQuestion is handled on **`/approval`**, not `/hook`. A Notification that says "which revision" paints the dashboard but does not create a held `QuestionRegistry` wait.
- Presence at the Mac makes the phone card read-only; isolated `vibebuddyd` does not claim presence.
- An expired Answer must not fall through to steer or `turn/start` (`CONTEXT.md` Session action).
- Multi-select questions need `answers` with arrays. The helper's `--text` only fills the first item (same as an older phone client).
- Codex Desktop questions may never be answerable from VibeBuddy. Record `verified-unreachable` if `pendingQuestion.answerable` is `false` or missing on a Desktop-origin session.

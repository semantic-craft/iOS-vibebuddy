# Cursor managed ACP

Verify recovery, complete native plans, tool results and cancellation for Cursor conversations created by VibeBuddy. Keep protocol, daemon HTTP, native app and physical-device evidence separate.

## Sub-features

- Continue the same provider session after restarting the isolated daemon, without replaying history as new output.
- Read the complete native plan and respond to its exact pending question.
- Merge partial tool updates by their original call ID into one result.
- Stop a genuinely waiting turn, remove its card and reject an expired response.

## How to get to it (user POV)

Start a Cursor task in a disposable project through an isolated VibeBuddy instance. Read its response, restart only that instance, and continue the same task. Ask for a native plan, inspect its beginning and end, then reject it. Request another plan and stop while it is waiting. An isolated Mac/iPhone screenshot and the actual response flow are required to claim native UI acceptance.

## Driving it with control-vibebuddy

1. Follow the feature index isolation requirements and run `launch`, then `doctor`. Keep the parent shell alive for the daemon lifetime. Record the fresh PID, binary/source hashes, CLI version and snapshot sourceID. Use a non-9876 port, disposable HOME/CFFIXED_USER_HOME and an isolated token; never print token contents.
2. For native Mac acceptance, build a separate `com.vibebuddy.e2e.<id>` bundle and supply the required `VIBEBUDDY_E2E_ROOT`, `VIBEBUDDY_E2E_ID`, and non-production `VIBEBUDDY_E2E_PORT`. Opt in with `VIBEBUDDY_E2E_CURSOR_ACP=1`; the app uses only `<root>/cursor-agent` and `<root>/cursor-acp`. Without the flag, Cursor stays disabled in the isolated app. Never use the installed production bundle for this recipe.
3. Check CLI authentication separately. A disposable HOME does not inherit Cursor login. When reuse of existing CLI authentication is authorized, a run-local wrapper may restore the authentication HOME only for the verified CLI executable. The wrapper must enforce this run's isolated hook port and token, use an explicit token-file choice, and disable terminal capture with dry-run. Keep the daemon HOME disposable and do not modify global hooks or copy credentials.
4. Register only the disposable project directory if needed; label bootstrap hooks as synthetic registration. Dispatch a real Cursor task that reads a unique marker from a file and remembers a different unique phrase. Save the actual source/session/completion IDs. Confirm the file tool has one original call ID and a completed result; answer text alone does not establish tool execution.
5. Stop only the identity-verified daemon and its descendants, preserving the disposable state. Relaunch the same binary, repeat health/authentication/ownership checks, and continue the same session. Require a fresh completion ID, the exact remembered phrase, and absence of the first-turn marker or replayed history. A failed load must remain unavailable without silently creating a new conversation.
6. Dispatch a real task with `mode: plan`. Ask for a native `CreatePlan` body longer than 1200 characters with a unique final marker. Read `pendingQuestion.questions[id=plan].text` and the legacy prompt from a fresh snapshot. Both must retain the complete body; a separately labeled provider todo list may follow it. Save the actual pending question ID. Plan-embedded todos are not live progress notifications.
7. Answer through `/answer` with `intent: answer`, `answers`, the exact `expectedQuestionId`, and the observed `expectedStatusSince`. Reject first and inspect the agent's subsequent response. A missing exact acknowledgement is inconclusive, not proof that rejection failed.
8. Request another genuine native plan. While its card is pending, send `intent: stop` with the current status timestamp. Require `done`, `userStopped`, and no actionable card. An answer using the expired question ID must return 409 and leave the completed turn unchanged. If no real card appears, record this step as not-run.
9. Capture actions and fresh snapshots before cleanup. Run the helper's `evidence` command while the instance is alive. Verify every owned descendant is gone independently of leader exit; then use `cleanup` for disposable state. Never reuse an old PID without identity verification.

### Native Mac regression checks

- Create the task through **New task**, inspect the full plan through its final marker, and click **Reject**. Record the provider session and completion identities alongside the actual native UI observations.
- After completion, use **Start a new turn…** in the same reader. Require the same provider session ID and a new completion, with no erroneous CLI-unavailable message or terminal fallback.
- Keep the result window visible while another app is active. A completed local body must load without indefinite **Loading** and remain unread. Record automatic acknowledgement separately after activation: it additionally requires body visibility, the correct key window and an active user. If it does not occur, verify explicit **Mark as read** for that completion and leave automatic acknowledgement unverified.
- For a genuinely pending plan, choose **More actions → Stop task**. Require the decision card to disappear, `userStopped` to become true, and the old question response to be rejected. Backend-only cancellation does not satisfy this native check.

## Gotchas

- `end_turn` can coexist with an upstream assistant-text error. Preserve the error and do not call the whole run clean merely because individual continuity or response checks passed.
- A recovered row is not a live ACP pipe. Replayed text, questions and approvals must not become new work or notifications.
- Tool call IDs may contain newlines and RPC request IDs may be numeric zero. Preserve both exactly.
- Only native requests prove remote interaction. Seeded questions, fixture tests and direct protocol probes cannot stand in for the daemon/app flow.
- Unsupported extension requests must not claim a task completed or an image failed. Image delivery, dynamic configuration, IDE takeover and Cloud are outside this recipe.

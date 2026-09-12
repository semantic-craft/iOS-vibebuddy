# Remote approval

When a Session is `needsResponse` with `waitKind=permission` and an answerable `pendingApproval`, the user reviews the tool (command preview or a bounded diff) and chooses **Approve**, **Deny**, **Always allow this**, or **Allow all this session**. The phone sends `POST /decision`; the held CLI hook then continues.

## Sub-features

- `appr-hold` holds a non-read-only `PreToolUse` (for example `Bash`) until a decision or the ~25s timeout.
- `appr-allow` **Approve** resolves `allow` and clears `pendingApproval`.
- `appr-deny` **Deny** resolves `deny`.
- `appr-always` **Always allow this** persists a rule (or echoes Claude `permission_suggestions`) when `canPersistDecision` is true.
- `appr-unauth` `POST /decision` without a bearer token is `401`.

## How to get to it (user POV)

- On Mac Dashboard or Glance card: **Approve** (split button), **More approval options** → **Always allow this** / **Allow all this session**, or **Deny**.
- On iPhone dashboard row / detail: the same **Approve** split button and **Deny**.
- On Watch: one-shot approve only when the full command is present (Demo `demo-build`); Edit diffs stay on the phone.
- The CLI approval hook is what raises the card (`hooks/approval-hook.sh` → `POST /approval`).

## Driving it with control-vibebuddy

Preconditions:

- Isolated daemon, `doctor` passed.
- No session `vb-verify-ap` already holding an approval.
- You will decide within ~25 seconds of `approval`.

- **Seed a turn.** Run `control-vibebuddy hook --agent claude --json '{"hook_event_name":"SessionStart","session_id":"vb-verify-ap","cwd":"/tmp/verify-gateway"}'` then `control-vibebuddy hook --agent claude --json '{"hook_event_name":"UserPromptSubmit","session_id":"vb-verify-ap","cwd":"/tmp/verify-gateway"}'`.
- **Hold a Bash permission.** Run `control-vibebuddy approval --session-id vb-verify-ap --cwd /tmp/verify-gateway --tool Bash --command 'rm -rf /tmp/vibebuddy-verify-should-ask'`. The helper backgrounds the holding POST.
- **See the card.** Run `id=$(control-vibebuddy wait-for --session-id vb-verify-ap --field pendingApproval)`. It polls `/snapshot` until the card exists and prints `pendingApproval.id`; the card is registered a moment after the holding POST returns, so one snapshot can legitimately miss it. Confirm the same snapshot shows `status=needsResponse`, `waitKind=permission`.
- **Approve.** Run `control-vibebuddy decision --approval-id "$id" --decision allow`. Exit is success and HTTP 200.
- **Confirm.** Snapshot again: `pendingApproval` is absent and `status=working`. The held `approval-vb-verify-ap.out` in the state dir contains `permissionDecision` `allow`.
- **Unauthenticated control.** `curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$VIBEBUDDY_QA_PORT/decision -d '{"approvalId":"x","decision":"allow"}'` prints `401`.
- **Proof.** Run `control-vibebuddy evidence --label remote-approval`. Keep the before/after snapshot extracts (card present, then cleared) in that folder. On a Mac UI, screenshot **Approve** / **Deny** on the isolated instance only if you also captured the HTTP before/after.

## Gotchas

- `Read`, `Grep`, `Glob`, `LS`, and the rest of `ApprovalShortCircuit.readOnlyTools` never become a permission card. `Bash` / `Edit` do (unless `bypassPermissions` or a matching always-allow rule). `AskUserQuestion` is listed in `readOnlyTools` but is *not* an exception to drive around: the server answers it before the short-circuit gate, so it raises a question card — see [question-reply](./question-reply.md).
- `approvalId` is a UUID from the daemon, not the session id. Always read it from the snapshot.
- A second `POST /decision` for the same id is `409` (`conflict`). Do not retry as if it were a network miss.
- Presence at the Mac can make the phone card read-only (`answerable: false`). Headless `vibebuddyd` reports not present, so isolated runs stay answerable.
- Codex Desktop / MCP elicitation may show a wait the companion cannot remotely resolve. If snapshot `pendingApproval.answerable` is `false`, the user must use the Mac prompt — do not call that path verified via `/decision`.
- Grok Build: **Allow** may not dismiss the native prompt unless Grok's permission mode agrees (`docs/getting-started.md`).
- Timeout with no decision returns an empty 200 to the hook (CLI shows its own prompt). That is not an Approve.

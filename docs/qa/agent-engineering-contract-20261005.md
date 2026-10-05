# VibeBuddy23 engineering contract evidence

Base: `2fa30a2d` (ticket PR #349). Branch: `codex/vibebuddy23-agent-contract`.
Scope: check output, read-only install plan and existing transaction receipts.
No app/runtime code changed. Original dirty checkout, installed app, production
port, credentials and private history remain untouched.

## Changes and preserved behavior

- `check.py --json` produces the same structured report on stdout and disk;
  progress is stderr, argument errors are JSON/2, unavailable checks fail, source
  drift and zero-test success remain rejected. Explicit skips are consumable.
- `redeploy-mac.sh --plan` / `--dry-run` expose candidate identity, target,
  process/port observations, future effects and unknowns without performing
  installation. Missing peer coordination, foreign process and unavailable
  observation block; the plan does not authorize installation.
- `--install --json` adds a receipt to the existing transaction, including early
  failure and rollback/recovery-required outcomes. No second installer or generic
  orchestration framework. Existing lock, signature, process and rollback guards
  remain in charge.
- MCP implementation is unchanged. A disposable-root invocation of the installed
  CLI verified newline framing, notification silence, tool `isError` and CLI
  0/1/2 with initialization and invalid inputs only. It requested no transcript
  and launched no app/daemon. This is compatibility evidence for the existing
  installed CLI, not a fresh build of this checkout.

## Reproduction and evidence

Before patch: `check.py docs --json` and `redeploy-mac.sh --plan ... --json`
both exited 2 with non-JSON usage output. Captured before any production effects.
During implementation, receipt consumption exposed missing stdout on a Bash EXIT
handler; the ordinary and rollback-error exits now explicitly serialize receipts.

Commands:

```bash
python3 tools/check.py workflow --json
python3 tools/check.py deployment --json
python3 tools/check.py docs --json
shellcheck -x tools/redeploy-mac.sh tools/lib/install-mac-app.sh tools/lib/mac-app-runtime.sh
```

`deployment` includes the existing disposable transaction/signature checks and
the new external CLI consumer. A copied, ad-hoc signed system `sleep` binary
named VibeBuddyMacApp is the isolated process fixture: it binds no port and is
not a product surrogate. The real plan identified it as a foreign peer, blocked,
and left it running. Only the fixture's own process was terminated on cleanup.
Plans and rejected invocations left fixture bytes unchanged. Disposable success,
health failure/rollback and restore failure receipts matched stdout, exit codes
and retained `receipt.json` on disk.

Sandboxed process observation is unavailable on this host and reports a parsed
skip plus a blocked plan; the same small test with approved process visibility
passed the real peer observation. This was not worked around by assuming no peer.
Heavy Swift/Xcode checks were not needed for these Python/Bash interfaces; the
host had concurrent load, so no parallel builds were added.

Local evidence is retained by the owner under `evidence/vibebuddy23/` beside the
isolated checkout (not committed). It contains before output, the installed CLI
hash/compatibility result, check `results.json` and numbered logs, and a hash
manifest. Public records intentionally omit personal absolute paths and logs.

## Review and delivery limits

Standards/spec review is performed in this task with no additional agents, as
explicitly requested. The normal independent Grok Build review remains a merge
gate; it is not claimed to have run. Draft PR only; no merge or GitHub-hosted CI.
The existing production installation/recovery workflow is not exercised against
the shared app in this ticket. No phone, Watch, voice, cloud or device behavior is
claimed verified. A later authorized install must recheck peers and consume its
own receipt. No new production permission is implied by the plan or these tests.

# 1.3.40 release verification

Combined MiniMax, language restart and October Codex/Cursor integration branch.
Original reviewed range: `a7ad6a04..6f9ec4ae`.

- Kit: 501 tests passed; Mac: 1,179 tests passed; iOS Simulator build passed.
- Agent integration presentation regression runner passed.
- Corrected MiniMax live request evidence is in `docs/agents/minimax-tts-research.md`.
- Language/restart and real agent/phone transport evidence remain in the source
  acceptance records; cloud-account and phone banner/sound limits are preserved.

## Independent Grok Build review

`grok-4.7-build-fast`, `xhigh`, session
`01a0f81b-2a61-7d80-afce-958e72d64410` returned MERGE WITH FIXES.

- Fixed: clear persistent Cursor discovery rows on unavailable discovery, with
  loss/recovery regression coverage.
- Fixed: discovery/resume snapshots without turn identity cannot erase a
  just-recovered completed turn; tested both idle and active rediscovery.
- Fixed: visible active Codex reader pages refresh every three seconds, stop
  on disappearance/selection changes, and avoid starting while paging earlier.
- Fixed: MiniMax speech error 1042 is rejected input, not a transport failure.
- Deliberate non-fix: the explicit QA cloud URL continues to fail closed when
  its isolation conditions are absent. Silently falling back to the production
  cloud client could make a misconfigured acceptance run use real credentials
  and accounts. The variable is test-only and is not forwarded by app relaunch.

After fixes: 29 Mac tests in six suites passed, including the two-status recovery
case and Cursor stale discovery regression. Final review and artifact validation
are recorded on the release PR.

# macOS 1.3.22 build 35 integration acceptance

## Scope and provenance

- Base: PR204 at `b283d2a9`.
- Completion recovery: `006fcb5a` (exact native turn mapping, persistence, conflict gates, diagnostics).
- Settings and project labels: merged PR205 `b9a942ce`.
- Version preparation: merged PR206 `5f1c7e0f`; integrated build advances 34 to 35 to distinguish contents.
- Other worktrees (`0e98`, `7dc8`, `c0e2`) and main checkout's VoiceSettingsTab changes were compared with PR205: all functional work is included. Original files are retained; no duplicate patch was applied.
- Independent integration review found no additional blocking issue.

## Automated checks

- Integrated core checks: 122 tests / 13 suites passed, including enabled real-record replay and project labels.
- Settings lifecycle probe: 15 checks passed.
- Notification delivery and quota gating: 12 additional tests passed (134 focused tests total).
- Release build 35 succeeded; stable Developer ID signature passed strict deep verification.
- Installed binary SHA256: `ccc608aa56e4c3b27d135d179afb74765c27cae485385d182de66a8096c80e19`, identical to build output.
- Installed native UI: project parent labels distinguish checkouts; summary/read-aloud idle unverified labels absent; purpose-specific model links; saved-key summary sample succeeded; read-aloud preview entered busy state then reported playback completed. No human hearing claim.
- Live Desktop task: real read-only Python sum, native turn `01a0a5aa-c19a-7452-93f9-ff2e8e82cbc2`, 240-character final body hash `5f76230e26f9b9ad7a0c06c0111b4d4ec0cbcbb839ccd40c463487ae1f730ace`; response source/session/completion identities and persisted native turn all match.
- Normal installed Keychain path: speech and recap presentation both generated successfully (131 and 110 characters). Nine live-task assertions passed, no E2E credential injection.
- Installed fault-recovery restart: 4/4 assertions passed. New PID/start time with identical binary; source/session/completion/body/unread/ack and persisted native turn remain unchanged.

Detailed local evidence: `.scratch/completion-summary-recovery/verification/`.

## Delivery boundary

User authorized local integration, commits, installation and unattended acceptance. Public release, tags, Sparkle publication and cross-machine synchronization are not performed by this task. Previous 1.3.21 bundle is retained as a local rollback artifact.

## Limits and retained diagnostic evidence

- Initial `codex exec` task completed, but this installation has no CLI hook intake for that task. The rollout monitor intentionally observes Desktop sources. The final successful acceptance used a real Desktop task; no source metadata or hooks were fabricated.
- The first Desktop validator needed to recognize the actual custom-tool-call envelope; failed evidence was retained and the parser was corrected while retaining exact call-ID and exit/output checks.
- Existing macOS notification permission is Denied, correctly displayed in Settings. Banner delivery remains blocked by that setting; it was not changed.
- Playback completion is automatic software evidence, not human hearing or a physical output-quality measurement. Phone/Watch and live microphone conversation were outside this Mac change acceptance.

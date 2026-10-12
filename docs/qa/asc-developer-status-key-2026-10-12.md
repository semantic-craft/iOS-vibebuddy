# Developer status credential split — 2026-10-12

Base: main `869a446d88c27c32074ee6583c039229ccc0c9b5`. The PR records the exact
independently reviewed head. Tooling only; no app/daemon behavior changed.

- Consulted the owner's Grok Bot for advice without sending secret material.
  Adopted separate variable sets, no fallback, and preserving the Anamra file.
- Saved the existing Developer `.p8` via the native 1Password file picker as a
  Private Document, `App Store Connect｜Developer（日常查询）｜API Key`.
  Readback showed the selected original filename and 257-byte attachment.
  Notes record actual Developer role, daily-query/Anamra purposes and rotation.
  The original file remains at its existing path; Anamra was not reconfigured.
- Added three `ASC_STATUS_*` variables to the existing helios Environment and
  updated the local ignored `.envrc` to load only this daily set by default.
  The tracked launcher clears inherited ASC variables and selects a set by
  command. Python maps the selected values to asc's canonical names only in
  its child environment. App Manager credentials remain for release commands.
- Actual `bash tools/appstore.sh status --version 1.3.38` using Developer
  returned `WAITING_FOR_REVIEW` and the same submission
  `cd7c12ff-a495-4ac4-95cd-5126cd0587e9`; no review submission was changed.
- Ten credential-free regressions passed, including explicit Developer status
  selection, App Manager release selection and failure with missing status
  credentials even when all release credentials are present. Shell syntax and
  project documentation checks passed.
- Updated the existing 1Password credential index with both command/variable
  assignments and rotation coordination. No key material is in Git or QA logs.

Sanitized evidence:
`~/Projects/_shared-work/iOS-vibebuddy/asc-developer-status-key-20261012/`.

Developer is an Apple role with upload permission, not a read-only role. The
project command boundary restricts its daily use to status. Release mutations
remain for the next authorized release, as in the original asc QA record.
No new app builds, device installation, Anamra run, key rotation or revocation
was performed. The original upload is verified through native save/readback;
attachment bytes were not exported again for hash comparison.

# asc iPhone release workflow acceptance — 2026-10-12

Base: main `803172698573c24160033d8a4a6449c03ac8b73b`. The PR records the exact
reviewed head. This change affects release tooling, not app/daemon behavior.

- Installed Homebrew `asc` 5.14.1 and checked its actual command help.
- Owner confirmed a dedicated App Manager team API Key. Original bytes are
  preserved as a 1Password Private Document; readback byte comparison passed.
  No private key material is in source control, prompts or QA logs.
- Runtime derivative stored in existing helios Environment; local `.envrc` and
  the tracked non-login launcher whitelist only three ASC variables. No
  `asc auth login`, Keychain copy, private-key-path fallback or session export.
- Real `bash tools/appstore.sh status --version 1.3.38` using this key returned
  version `1.3.38`, `WAITING_FOR_REVIEW`, and submission
  `cd7c12ff-a495-4ac4-95cd-5126cd0587e9`. This agrees with the prior native web
  submission. Querying does not alter that submission.
- Six credential-free boundary regressions passed: wrong IPA build rejected,
  wrong remote build blocked before version mutation, missing confirmation
  blocked before credential read, foreign ASC profiles/key paths removed, active review resubmission blocked, and
  subcommand help works without any loader/credentials.
- Offline plan parsed both existing release-note sections; asc metadata validation
  accepted the two notes-only locale files with zero warnings/errors. Shell syntax
  and project documentation checks passed.
- Re-export of the existing 1.3.38 (73) archive with the scoped system PATH
  returned `EXPORT SUCCEEDED`; no second upload was performed.

Durable sanitized status/plan and check/review evidence:
`~/Projects/_shared-work/iOS-vibebuddy/asc-release-workflow-20261012/`.

Live upload, stage and submit through asc are not exercised on the already
submitted 1.3.38. Command contracts and guards were checked; the next authorized
new release must exercise those mutations and read back its actual results.
No new phone/Mac/Watch binary was built or installed for the tooling change.
The existing archive is reused only to verify the scoped system-PATH export
recovery; it is not uploaded again.

# App Store Connect CLI release entry

Use [rorkai asc](https://github.com/rorkai/App-Store-Connect-CLI) for the iPhone
steps after the audited archive/export. Tested with Homebrew `asc` 5.14.1.
Mac Developer ID signing, notarization, GitHub Releases and Sparkle stay in
`tools/release-mac.sh`; asc does not replace device acceptance or Apple review.

## Authentication on Helios

The owner's App Manager team key is stored as a Document in 1Password's Private
vault, titled `App Store Connect｜VibeBuddy Release CLI｜API Key`. Its original
bytes are preserved. Key ID and Issuer ID are metadata, not key material.

The existing `helios` Environment mounted at `~/.env` has two credential sets:

| Purpose | Environment names | Commands |
| --- | --- | --- |
| Daily query, existing Developer key | `ASC_STATUS_KEY_ID`, `ASC_STATUS_ISSUER_ID`, `ASC_STATUS_PRIVATE_KEY_B64` | `status` |
| Release, dedicated App Manager key | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_B64` | `upload`, `stage`, `submit` |

The Developer original is also a Private Document titled
`App Store Connect｜Developer（日常查询）｜API Key`. Developer is not an Apple
read-only role: it can upload builds. Our entry uses it only for status queries.
The existing original file remains in place for Anamra; rotating it requires
coordinating that consumer, the Document and the Environment derivative.

The local, globally ignored `.envrc` whitelists only the daily-query set. Release
credentials load only when explicitly invoking a confirmed release command.
`bash tools/appstore.sh` invokes the existing Helios loader from a non-login
process, clears inherited ASC variables and requests only the selected set.
For `status`, Python maps `ASC_STATUS_*` to asc's canonical `ASC_*` names only
in the child environment. Other ASC variables/profiles are removed. Missing
selected credentials fail; status never falls back to the App Manager key.

Do not use `asc auth login`, which copies key material to Keychain/config.
Do not print the FIFO, environment, base64, PEM or JWT; do not enable shell
tracing/debug. `*.p8` and `.asc/` are ignored. Rotate the Document and derived
Environment together, then verify status before retiring the old key. Other
machines need their own authorized 1Password mount/loader.

Team keys apply to the team's apps. Apple requires Account Holder, Admin or
App Manager for [review submission](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/).
Existing Developer keys can query/upload but do not authorize review submission.

## Release commands

From the repository root:

```bash
# Offline plan: no credentials, no network, no remote upload reservations.
bash tools/appstore.sh plan

# Preserve the existing archive/export/signature/APNs/component audits.
bash tools/archive-ios.sh
bash tools/appstore.sh upload --confirm

# Use the buildId returned by upload. Never select "latest" across releases.
bash tools/appstore.sh stage --build-id <build-id> --review-notes <approved-text-file> --confirm
bash tools/appstore.sh submit --confirm
bash tools/appstore.sh status
# Explicit historical version, e.g. this release:
bash tools/appstore.sh status --version 1.3.38
```

`--confirm` executes an operation already authorized by the owner; it does not
grant authorization. Upload checks the IPA bundle/version/build against
`project.yml`. Stage verifies exact app/version/build and VALID processing before
mutations, uses the two release-note sections in `docs/release-notes-ios-<version>.md`,
leaves other listing fields/locales unmanaged, updates only reviewer notes and
release type, and sets automatic release after approval. Existing review contact
details must be present; a missing detail is an explicit preparation boundary.

Stage stops before submission. Generated notes are retained in the ignored stable
`VibeBuddyApp/build/asc-metadata-<version>-<build>/` directory. Its checkpoint is under ignored
`VibeBuddyApp/build/asc-stage-<version>-<build>.json`; after failure inspect actual
remote state and blockers before rerunning. Metadata and review details may
already be applied. Submit selects the exact project build number and version.
After unknown network results, inspect status before retrying. Never withdraw a
waiting/reviewing version just to test the tool.

Xcode export uses system PATH only for `-exportArchive`: Homebrew rsync 3.5.1
rejects Apple's `-E` flags, causing `Copy failed`. Archive retains the normal
XcodeGen PATH. The CLI's `builds upload --dry-run` reserves remote operations,
so it is deliberately not used as our offline plan.

## Verification

Run `python3 tools/tests/appstore-regression.py`, `bash -n tools/appstore.sh
tools/archive-ios.sh`, and `tools/check.py docs`. Use the real read-only status
command to prove authentication. Live upload/stage/submit must wait for an
authorized new release; a mock or command plan does not prove those mutations.
Record results in [the original asc QA record](qa/asc-release-workflow-2026-10-12.md) and
[credential split acceptance](qa/asc-developer-status-key-2026-10-12.md).

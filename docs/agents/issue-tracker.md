# Issue tracker: Local Markdown

Issues and PRDs for this repo live as markdown files in `.scratch/`.
GitHub Issues on `semantic-craft/iOS-vibebuddy` is **not** used for work tracking.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The PRD is `.scratch/<feature-slug>/PRD.md`
- Implementation issues are `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## Existing features (as of setup)

The convention is already in use:

- `.scratch/ios-voice-parity/issues/` (01–04)
- `.scratch/bg-sound-parity/issues/` (01)
- `.scratch/design-polish/issues/` (01)
- `.scratch/dynamic-island/issues/` (01)
- `.scratch/failure-signal/issues/` (01)
- `.scratch/realtime-verify/issues/` (01)

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/` (creating the directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the issue number directly.

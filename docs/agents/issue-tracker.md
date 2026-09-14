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

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `.scratch/<effort>/map.md` (the Destination / Notes / Decisions-so-far / Not yet specified / Out of scope body).
- **Child ticket**: `.scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records the ticket type (`research`/`prototype`/`grilling`/`task`); a `Status:` line records `open`/`claimed`/`resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every file it lists is `resolved`.
- **Frontier**: scan `.scratch/<effort>/issues/` for files that are open, unblocked, and unclaimed; first by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under an `## Answer` heading, set `Status: resolved`, then append a context pointer (gist + link) to the map's Decisions-so-far in `map.md`.
- **Research assets**: a research ticket's findings go to `.scratch/<effort>/research/<slug>.md` (this repo keeps research notes beside the PRD, e.g. `.scratch/watch-quota/RESEARCH.md`), linked from the ticket's Answer; no `research/<name>` branch is needed because `.scratch/` is untracked.

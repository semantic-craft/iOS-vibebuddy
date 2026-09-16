# Mac performance verification

For the native reader experiment and navigation checks, use [reader-README.md](reader-README.md).

For the standalone ledger comparison, use [ledger-README.md](ledger-README.md).

## Snapshot publication probe

From the repository root, after a Debug Mac app build has produced the package
objects and module maps under `VibeBuddyMacApp/build`:

```sh
python3 tools/mac-performance-qa/publication.py after
python3 tools/mac-performance-qa/publication.py before .scratch/mac-performance/baseline/MenuBarModel.swift
```

`before` requires a MenuBarModel source saved **before** the optimization. It
extracts the actual original snapshot-assignment statements from `startPolling`
and exposes them as the probe entry point; it does not substitute a mock model.
Both variants compile the full real app sources and instantiate the actual
`MenuBarModel(runtimeEnabled: false)`. Other app sources and linked package
objects remain common to both runs. The comparison counts `objectWillChange`
from 100 unchanged snapshot applications; it does not measure a full poll,
CPU, frame rate, or rendering performance.

The same probe checks a changed directory list, expired authority, recovery
publication, missing authority, the 24-hour current-session boundary, and the
180-second waiting boundary. The production recap view's five-second
TimelineView remains responsible for passage-of-time invalidation.

The runner bundles the executable under a unique E2E identifier, uses a disposable
HOME and E2E storage root, and disables runtime services. It does not bind a
server, run a second menu-bar instance, start audio, or read production sessions.
Artifacts, compile logs and results are in
`.scratch/mac-performance/publication-before` and `publication-after`.
Use `VIBEBUDDY_QA_BUILD_ROOT` to select another DerivedData directory containing
`Build` and `SourcePackages`. If Xcode used a separate package checkout directory,
set `VIBEBUDDY_QA_PACKAGES_ROOT` to that `SourcePackages` directory.

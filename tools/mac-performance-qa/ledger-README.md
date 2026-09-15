# Standalone ledger A/B

Build only, from the repository root:

```sh
python3 tools/mac-performance-qa/ledger-build.py
```

Defaults use `.scratch/mac-performance/DerivedData` and
`VibeBuddyMacApp/build/SourcePackages`. Override with `VIBEBUDDY_QA_BUILD_ROOT`
and `VIBEBUDDY_QA_PACKAGES_ROOT` when needed. No SPM build or timing run occurs.

The builder freezes the baseline `ToolLedger.swift` from `f62c2946` and the
current working source. Each gets only an import for the existing public
`HookEvent` type. Both are compiled as local `LedgerProbe.ToolLedger` against
the same fresh Debug dependencies. It copies `ToolLedgerPerformanceTests.swift`
unchanged and runs its XCTest suite; it does not reimplement the fixture or
ledger. Source hashes and compiler commands are retained under
`.scratch/mac-performance/ledger-standalone`.

When the host is available for timing, run these serially and preserve stdout:

```sh
VIBEBUDDY_LEDGER_BENCHMARK=1 .scratch/mac-performance/ledger-standalone/before/LedgerProbe
VIBEBUDDY_LEDGER_BENCHMARK=1 .scratch/mac-performance/ledger-standalone/after/LedgerProbe
```

Each run measures the existing three operations, ten calls per trial, three
trials, 12,500 records; fixture creation is outside its measured interval.
It verifies the persisted ledger can be read back. The executable exits with
failure if the XCTest fails, is skipped, or does not execute exactly one test.
The fixture creates and removes only its own UUID directory under the temporary
directory. It does not initialize the app, access production state or bind ports.

Run in reverse order as well if CPU/disk load changes between runs. Report the
individual operation/trial times and host conditions; the result measures this
ledger workload, not application CPU or UI responsiveness.

"""Compile the real ledger before/after with the unchanged performance fixture."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
build = Path(os.environ.get("VIBEBUDDY_QA_BUILD_ROOT", root / ".scratch/mac-performance/DerivedData"))
packages = Path(os.environ.get("VIBEBUDDY_QA_PACKAGES_ROOT", root / "VibeBuddyMacApp/build/SourcePackages"))
work = root / ".scratch/mac-performance/ledger-standalone"
work.mkdir(parents=True, exist_ok=True)
relative = "VibeBuddyMac/Sources/VibeBuddyMacCore/ToolLedger.swift"
baseline = subprocess.run(["git", "show", "f62c2946:" + relative], check=True, capture_output=True).stdout
sources = {"before": baseline, "after": (root / relative).read_bytes()}
fixture = root / "VibeBuddyMac/Tests/VibeBuddyMacCoreTests/ToolLedgerPerformanceTests.swift"
fixture_copy = work / fixture.name
fixture_copy.write_bytes(fixture.read_bytes())
main = work / "ledger-main.swift"
main.write_bytes((root / "tools/mac-performance-qa/ledger-main.swift").read_bytes())
products = build / "Build/Products/Debug"
modulemaps = build / "Build/Intermediates.noindex/GeneratedModuleMaps"
developer = Path(subprocess.run(["xcode-select", "-p"], check=True, capture_output=True, text=True).stdout.strip())
frameworks = developer / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
test_libraries = developer / "Platforms/MacOSX.platform/Developer/usr/lib"
manifest = {"fixture_sha256": hashlib.sha256(fixture_copy.read_bytes()).hexdigest(), "baseline_commit": "f62c2946"}

for variant, contents in sources.items():
    directory = work / variant
    directory.mkdir(exist_ok=True)
    (directory / "ToolLedger.original.swift").write_bytes(contents)
    ledger = directory / "ToolLedger.swift"
    ledger.write_bytes(b"import VibeBuddyMacCore\n" + contents)
    manifest[variant + "_sha256"] = hashlib.sha256(contents).hexdigest()
    executable = directory / "LedgerProbe"
    command = ["swiftc", "-swift-version", "6", "-parse-as-library", "-module-name", "LedgerProbe",
               "-I", str(products), "-I", str(test_libraries), "-L", str(test_libraries),
               "-F", str(products), "-F", str(frameworks)]
    for modulemap in modulemaps.glob("*.modulemap"):
        command += ["-Xcc", "-fmodule-map-file=" + str(modulemap)]
    includes = list((packages / "checkouts").glob("*/Sources/*/include"))
    includes += list((packages / "checkouts/swift-cmark").glob("*/include"))
    for include in includes:
        command += ["-I", str(include)]
    command += [str(ledger), str(fixture_copy), str(main)]
    command += list(map(str, products.glob("*.o")))
    command += ["-framework", "XCTest", "-framework", "Sparkle", "-lsqlite3", "-lz", "-lc++",
                "-Xlinker", "-rpath", "-Xlinker", str(products),
                "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                "-Xlinker", "-rpath", "-Xlinker", str(test_libraries), "-o", str(executable)]
    (directory / "compile-command.json").write_text(json.dumps(command, indent=2))
    result = subprocess.run(command, capture_output=True, text=True)
    (directory / "compile.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        print(result.stderr[-5000:])
        sys.exit(result.returncode)
    print("Built", executable, flush=True)
(work / "source-hashes.json").write_text(json.dumps(manifest, indent=2))
print("Both binaries ready; no timing run was started.")

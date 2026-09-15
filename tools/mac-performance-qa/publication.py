"""Build a frozen copy of the real app with the snapshot publication probe."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path.cwd()
build = Path(os.environ.get("VIBEBUDDY_QA_BUILD_ROOT", root / "VibeBuddyMacApp/build"))
output = root / ".scratch/mac-performance"
variant = sys.argv[1]
assert variant in ("before", "after")
work = output / ("publication-" + variant)
work.mkdir(parents=True, exist_ok=True)
source_copy = work / "Sources"
source_copy.mkdir(exist_ok=True)
sources = []
for source in (root / "VibeBuddyMacApp/Sources").glob("*.swift"):
    text = source.read_text()
    if source.name == "VibeBuddyMenuBarApp.swift":
        text = text.replace("@main\n", "")
    elif source.name == "MenuBarModel.swift" and variant == "before":
        baseline = Path(sys.argv[2]) if len(sys.argv) > 2 else output / "baseline/MenuBarModel.swift"
        text = baseline.read_text()
        start = text.index("                self.snapshotSourceID = snapshot.sourceID", text.index("private func startPolling"))
        end = text.index("                self.codexAppServerDiagnostics =", start)
        # Preserve the old production statements; substitute only the supplied clock.
        block = text[start:end].replace("Date()", "observedAt")
        start = text.index("                self.tokenConsumption = snapshot.tokenConsumption", end)
        end = text.index("                self.lifecycleTimeline =", start)
        block += text[start:end]
        method = "    func applySnapshot(_ snapshot: Snapshot, observedAt: Date) {\n" + block + "    }\n"
        text = text.replace("    private func startPolling() {", method + "    private func startPolling() {")
    target = source_copy / source.name
    target.write_text(text)
    sources.append(target)
probe = source_copy / "publication-main.swift"
probe.write_text((root / "tools/mac-performance-qa/publication-main.swift").read_text())
sources.append(probe)

products = build / "Build/Products/Debug"
intermediate = build / "Build/Intermediates.noindex"
app = work / "Publication.app"
(app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
identifier = "publication-" + variant
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "com.vibebuddy.e2e." + identifier,
    "CFBundleExecutable": "Publication",
    "CFBundlePackageType": "APPL",
}))
executable = app / "Contents/MacOS/Publication"
command = [
    "swiftc", "-swift-version", "6", "-parse-as-library", "-whole-module-optimization",
    "-module-name", "VibeBuddyMacApp", "-I", str(products), "-F", str(products),
]
for modulemap in (intermediate / "GeneratedModuleMaps").glob("*.modulemap"):
    command += ["-Xcc", "-fmodule-map-file=" + str(modulemap)]
packages = Path(os.environ.get("VIBEBUDDY_QA_PACKAGES_ROOT", build / "SourcePackages"))
checkouts = packages / "checkouts"
includes = list(checkouts.glob("*/Sources/*/include"))
includes += list((checkouts / "swift-cmark").glob("*/include"))
for include in includes:
    command += ["-I", str(include)]
command += list(map(str, sources)) + list(map(str, products.glob("*.o")))
command += ["-framework", "Sparkle", "-lsqlite3", "-lz", "-lc++", "-Xlinker", "-rpath", "-Xlinker", str(products), "-o", str(executable)]
result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
(work / "compile.log").write_text(result.stdout)
print(result.stdout[-5000:])
print("compile", result.returncode, flush=True)
if result.returncode:
    sys.exit(result.returncode)

runtime = work / "runtime"
runtime.mkdir(exist_ok=True)
environment = dict(
    os.environ, HOME=str(runtime), CFFIXED_USER_HOME=str(runtime),
    VIBEBUDDY_E2E_ID=identifier, VIBEBUDDY_E2E_ROOT=str(runtime),
    VIBEBUDDY_E2E_PORT="19879", EXPECT_DEDUP="1" if variant == "after" else "0",
)
result = subprocess.run([str(executable)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
(work / "result.txt").write_text(result.stdout)
print(result.stdout)
sys.exit(result.returncode)

#!/usr/bin/env python3
"""Compile actual reader sources into an isolated native QA app using existing Debug packages."""
import argparse
import pathlib
import plistlib
import subprocess
import shutil

root = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("label")
parser.add_argument("--reader-source", type=pathlib.Path)
args = parser.parse_args()
products = root / "VibeBuddyMacApp/build/Build/Products/Debug"
app = root / ".scratch/mac-performance" / f"ReaderQA-{args.label}.app"
macos = app / "Contents/MacOS"
macos.mkdir(parents=True, exist_ok=True)
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": f"local.vibebuddy.reader-qa.{args.label}",
    "CFBundleExecutable": "ReaderQA", "CFBundleName": "Reader performance QA",
    "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0",
}))
sources = root / "VibeBuddyMacApp/Sources"
module_flags = []
for modulemap in (root / "VibeBuddyMacApp/build/SourcePackages/checkouts").glob("*/Sources/*/include/module.modulemap"):
    module_flags += ["-Xcc", "-fmodule-map-file=" + str(modulemap), "-Xcc", "-I" + str(modulemap.parent)]
for modulemap in (root / "VibeBuddyMacApp/build/Build/Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
    module_flags += ["-Xcc", "-fmodule-map-file=" + str(modulemap), "-Xcc", "-I" + str(modulemap.parent)]
for modulemap in (root / "VibeBuddyMacApp/build/SourcePackages/checkouts/swift-cmark").rglob("module.modulemap"):
    module_flags += ["-Xcc", "-fmodule-map-file=" + str(modulemap), "-Xcc", "-I" + str(modulemap.parent)]
command = ["xcrun", "swiftc", "-g", "-Onone", "-parse-as-library", "-target", "arm64-apple-macos14.0", "-I", str(products), *module_flags,
    str(pathlib.Path(__file__).with_name("reader-benchmark.swift")),
    str(args.reader_source or sources / "SessionReaderView.swift"), str(sources / "HistoryMarkdownView.swift"), str(sources / "MacTheme.swift"),
    *map(str, products.glob("*.o")), "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "Security", "-framework", "Network", "-lsqlite3", "-o", str(macos / "ReaderQA")]
raise_code = subprocess.run(command).returncode
if raise_code: raise SystemExit(raise_code)
resources = app / "Contents/Resources"
resources.mkdir(exist_ok=True)
for bundle in products.glob("*.bundle"):
    shutil.copytree(bundle, resources / bundle.name, dirs_exist_ok=True)
print(app)

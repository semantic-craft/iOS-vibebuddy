#!/usr/bin/env python3
"""Run actual ReadAloud with silent audio and injected synthesis, without credentials or network."""
import argparse
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--reader-source", type=pathlib.Path, default=root / "VibeBuddyMacApp/Sources/ReadAloud.swift")
parser.add_argument("--scratch-path", type=pathlib.Path, default=pathlib.Path(tempfile.gettempdir()) / "vibebuddy-speech-regression-kit")
args = parser.parse_args()
build = ["swift", "build", "--package-path", str(root / "VibeBuddyKit"), "--scratch-path", str(args.scratch_path)]
subprocess.run(build, check=True)
products = pathlib.Path(subprocess.check_output(build + ["--show-bin-path"], text=True).strip())
modules = products / "Modules" if (products / "Modules").is_dir() else products
objects = list((products / "VibeBuddyKit.build").glob("*.o")) or [products / "VibeBuddyKit.o"]
with tempfile.TemporaryDirectory(prefix="vibebuddy-speech-playback-") as directory:
    executable = pathlib.Path(directory) / "SpeechPlaybackQA"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-I", str(modules),
        str(args.reader_source), str(pathlib.Path(__file__).with_name("main.swift")),
        *map(str, objects),
        "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)

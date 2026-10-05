#!/usr/bin/env python3
"""Scoped local checks with source identity, elapsed times and explicit E2E limits."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


class CheckArguments(argparse.ArgumentParser):
    def error(self, message):
        if "--json" in sys.argv:
            print(json.dumps({"schema_version": 1, "status": "error", "exit_code": 2,
                              "error": {"code": "invalid_arguments", "message": message}}))
            raise SystemExit(2)
        super().error(message)


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def source_state():
    """Fingerprint tracked changes and untracked sources without saving their content."""
    untracked = git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0")
    digest = hashlib.sha256(git("diff", "--binary", "HEAD"))
    for raw in sorted(filter(None, untracked)):
        path = ROOT / os.fsdecode(raw)
        digest.update(raw + b"\0")
        content = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()
        digest.update(hashlib.sha256(content).digest())
    return {
        "head": git("rev-parse", "HEAD").decode().strip(),
        "branch": git("branch", "--show-current").decode().strip(),
        "status": git("status", "--short").decode().splitlines(),
        "worktree_sha256": digest.hexdigest(),
    }


def check_docs():
    # Stable entry points plus the Markdown files currently being edited.
    paths = {"AGENTS.md", "README.md", "README.zh-CN.md", "CONTRIBUTING.md",
             "docs/agents/development.md", "docs/agents/skills/vibebuddy-handoff/SKILL.md"}
    for args in [("diff", "--name-only", "HEAD", "-z"),
                 ("ls-files", "--others", "--exclude-standard", "-z")]:
        paths.update(os.fsdecode(p) for p in git(*args).split(b"\0") if p.endswith(b".md"))
    errors = []
    checked = 0
    for relative in sorted(paths):
        path = ROOT / relative
        if not path.exists():
            continue  # A removed document has no outgoing links.
        body = re.sub(r"```.*?```", "", path.read_text(), flags=re.S)
        for target in re.findall(r"\[[^\]]*\]\(([^)]+)\)", body):
            target = target.strip().strip("<>")
            url = urlsplit(target)
            if url.scheme or url.netloc or not url.path:
                continue
            if url.path.startswith(("~", "/")):
                continue  # Machine-local evidence is not a portable repo dependency.
            resolved = path.parent / unquote(url.path)
            checked += 1
            if not resolved.exists():
                errors.append(f"{relative}: missing link target {target}")
    print(f"Checked {checked} relative link targets in {len(paths)} Markdown files.")
    print("Anchor spelling, rendering and external URLs require separate review.")
    for error in errors:
        print(error)
    return int(bool(errors))


def commands(profile, test_filter):
    if profile == "docs":
        return [["git", "diff", "--check"], [sys.executable, __file__, "--check-docs"]]
    if profile == "workflow":
        return [[sys.executable, "tools/tests/check-runner-regression.py"],
                [sys.executable, "tools/tests/resolved-regression.py"]]
    if profile == "deployment":
        scripts = ["tools/redeploy-mac.sh", "tools/lib/install-mac-app.sh",
                   "tools/lib/mac-app-runtime.sh", "tools/tests/deploy-mac-regression.sh"]
        return [["bash", "-n", p] for p in scripts] + [
            ["bash", "tools/tests/deploy-mac-regression.sh"],
            [sys.executable, "tools/tests/engineering-contract-regression.py"]]
    if profile in ("kit", "mac"):
        cmd = ["swift", "test", "--package-path", "VibeBuddyKit" if profile == "kit" else "VibeBuddyMac"]
        if test_filter:
            cmd += ["--filter", test_filter]
        if profile == "mac":
            cmd = [sys.executable, str(ROOT / "tools/with-resolved.py"), *cmd]
        return [cmd]
    if profile in ("settings", "integration"):
        return [["bash", "tools/verify-settings-credentials.sh" if profile == "settings"
                 else "tools/tests/agent-integration-regression.sh"]]
    folder = "VibeBuddyMacApp" if profile == "mac-build" else "VibeBuddyApp"
    return [["xcodegen", "generate", "--spec", f"{folder}/project.yml"],
            ["xcodebuild", "-project", f"{folder}/{folder}.xcodeproj", "-scheme", folder,
             "-configuration", "Debug", "-destination",
             "platform=macOS" if profile == "mac-build" else "generic/platform=iOS Simulator",
             "-derivedDataPath", f"{folder}/build/check", "CODE_SIGNING_ALLOWED=NO", "build", "-quiet"]]


LIMITS = {
    "workflow": "Check-report failure/drift and SwiftPM pin preservation regressions; no app acceptance.",
    "docs": "Local link targets and diff whitespace only; no rendered or external-link verification.",
    "deployment": "Disposable replacement/signature tests; no production install, :9876, Sparkle or device acceptance.",
    "kit": "Shared logic tests; no native UI or real agent acceptance.",
    "mac": "Mac package tests; no installed app, real agent or device acceptance.",
    "settings": "Credential state with in-memory storage; no real Keychain/UI acceptance.",
    "integration": "Agent integration state regression; no real hook delivery or UI acceptance.",
    "mac-build": "Unsigned build only; no app launch, signature or runtime acceptance.",
    "ios-build": "Simulator build only; no launch, physical iPhone or Watch acceptance.",
}


def main():
    parser = CheckArguments(description=__doc__)
    parser.add_argument("profile", nargs="?", choices=LIMITS)
    parser.add_argument("--filter", help="Swift test filter for kit/mac; omit to run that package's suite")
    parser.add_argument("--output", type=Path, help="New evidence directory outside tracked source paths")
    parser.add_argument("--list", action="store_true", help="List checks and what they cannot prove")
    parser.add_argument("--json", action="store_true", help="Emit one JSON result on stdout; progress stays on stderr")
    parser.add_argument("--source-state", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--check-docs", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.source_state:
        print(json.dumps(source_state(), indent=2))
        return 0
    if args.check_docs:
        return check_docs()
    if args.list:
        if args.json:
            print(json.dumps({"schema_version": 1, "profiles": LIMITS, "exit_code": 0}))
            return 0
        for profile, limit in LIMITS.items():
            print(f"{profile}: {limit}")
        return 0
    if not args.profile:
        parser.error("choose a profile, or use --list")
    if args.filter and args.profile not in ("kit", "mac"):
        parser.error("--filter applies only to kit/mac")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output = (args.output or ROOT / ".scratch" / "checks" / f"{stamp}-{args.profile}").resolve()
    if output.is_relative_to(ROOT):
        ignored = subprocess.run(["git", "check-ignore", "-q", str(output)], cwd=ROOT).returncode == 0
        if not ignored:
            parser.error("evidence inside the repo must be gitignored; use .scratch/checks or an external directory")
    try:
        output.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        parser.error("evidence directory already exists; choose a new directory")
    before = source_state()
    report = {"schema_version": 1, "started_utc": stamp, "profile": args.profile, "source_before": before,
              "checks": [], "limitations": LIMITS[args.profile]}
    progress = sys.stderr if args.json else sys.stdout
    planned = commands(args.profile, args.filter)
    report["planned_commands"] = planned
    result = 0
    try:
        for index, cmd in enumerate(planned, 1):
            log = output / f"{index:02d}.log"
            print(f"Running: {' '.join(cmd)}\nLog: {log}", file=progress, flush=True)
            start = time.monotonic()
            try:
                with log.open("w") as stream:
                    code = subprocess.run(cmd, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT).returncode
            except OSError as exc:
                log.write_text(str(exc) + "\n")
                code = 127
            verification_error = None
            with log.open(errors="replace") as stream:
                skips = [line.strip() for line in stream if line.startswith(("SKIP ", "SKIP:"))]
            if code == 0 and args.profile in ("kit", "mac"):
                text = log.read_text(errors="replace")
                counts = re.findall(r"(?:Executed|Test run with) ([0-9]+) tests?\b", text)
                if "No matching test cases were run" in text or not any(int(n) > 0 for n in counts):
                    verification_error = "Swift reported success but no executed tests; check the filter and log."
            report["checks"].append({"command": cmd, "exit_code": code,
                                     "status": ("passed_with_skips" if skips else "passed") if code == 0 and not verification_error else "failed",
                                     "skips": skips,
                                     "verification_error": verification_error,
                                     "seconds": round(time.monotonic() - start, 3), "log": log.name})
            print(f"{'PASS' if code == 0 and not verification_error else 'FAIL'} ({report['checks'][-1]['seconds']}s)", file=progress, flush=True)
            if code or verification_error:
                result = 1
                break
    except KeyboardInterrupt:
        result = 130
        report["interrupted"] = True
    except (OSError, subprocess.SubprocessError) as exc:
        result = 1
        report["error"] = {"code": "check_unavailable", "message": str(exc)}
    finally:
        report["not_run"] = planned[len(report["checks"]):]
        report["source_after"] = source_state()
        report["source_changed_during_run"] = report["source_after"] != before
        if report["source_changed_during_run"]:
            result = result or 1
        report["exit_code"] = result
        report["status"] = ("passed_with_skips" if any(c["skips"] for c in report["checks"]) else "passed") if result == 0 else "failed"
        report["result_path"] = str(output / "results.json")
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Result: {output / 'results.json'}\nLimit: {report['limitations']}", file=progress)
        if report["source_changed_during_run"]:
            print("Source changed during checks; inspect before claiming this version passed.", file=progress)
        if args.json:
            print(json.dumps(report))
    return result


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.SubprocessError) as exc:
        if "--json" not in sys.argv:
            raise
        print(json.dumps({"schema_version": 1, "status": "error", "exit_code": 1,
                          "error": {"code": "check_unavailable", "message": str(exc)}}))
        sys.exit(1)

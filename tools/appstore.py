#!/usr/bin/env python3
"""VibeBuddy iOS App Store workflow; asc reads credentials from 1Password in memory."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
APP = "6777469338"


def run(args, env=None, capture=False):
    result = subprocess.run(args, env=env, text=True, capture_output=capture)
    if result.returncode:
        # Captured credential commands must never leak stdout/stderr on failure.
        raise RuntimeError(f"{args[0]} failed (exit {result.returncode})")
    return json.loads(result.stdout) if capture else None


def auth_env():
    env = os.environ.copy()
    # Do not silently combine another account/profile with this project's key.
    for key in list(env):
        if key.startswith("ASC_"):
            del env[key]
    required = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_B64")
    if any(not os.environ.get(k) for k in required):
        raise RuntimeError("missing ASC credentials; run tools/appstore.sh with 1Password unlocked")
    # asc supports ASC_PRIVATE_KEY_B64 directly; only pass the three selected variables.
    for key in required:
        env[key] = os.environ[key]
    base64.b64decode(env["ASC_PRIVATE_KEY_B64"], validate=True)
    env.update(ASC_BYPASS_KEYCHAIN="1", ASC_STRICT_AUTH="1")
    return env


def release_identity():
    source = (ROOT / "VibeBuddyApp/project.yml").read_text()
    values = []
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        found = set(re.findall(rf'^\s*{key}:\s*"([^"\n]+)"', source, re.M))
        if len(found) != 1:
            raise ValueError(f"shipping targets disagree on {key}")
        values.append(found.pop())
    return values


def notes(version):
    source = (ROOT / f"docs/release-notes-ios-{version}.md").read_text()
    result = {}
    for heading, locale in (("English", "en-US"), ("简体中文", "zh-Hans")):
        match = re.search(rf'^## {heading}\s*\n(.*?)(?=^## |\Z)', source, re.M | re.S)
        if not match or not 0 < len(match[1].strip()) <= 4000:
            raise ValueError(f"missing/invalid {heading} release notes")
        result[locale] = {"whatsNew": match[1].strip()}
    return result


def check_ipa(path, version, build):
    with zipfile.ZipFile(path) as ipa:
        candidates = [n for n in ipa.namelist()
                      if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(candidates) != 1:
            raise ValueError("IPA must contain exactly one top-level app")
        info = plistlib.loads(ipa.read(candidates[0]))
        expected = {"CFBundleIdentifier": "com.vibebuddy.app",
                    "CFBundleShortVersionString": version, "CFBundleVersion": build}
        if any(str(info.get(k)) != v for k, v in expected.items()):
            raise ValueError("IPA bundle/version/build does not match project.yml; archive again")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    status = commands.add_parser("status", help="read-only App Review status")
    status.add_argument("--version", help="defaults to project.yml")
    commands.add_parser("plan", help="offline notes and command plan; no credentials or network")
    upload = commands.add_parser("upload", help="upload the previously audited IPA")
    upload.add_argument("--ipa", type=Path, default=ROOT / "VibeBuddyApp/build/export/VibeBuddyApp.ipa")
    stage = commands.add_parser("stage", help="create version, update notes and attach exact build")
    stage.add_argument("--build-id", required=True)
    stage.add_argument("--review-notes", type=Path, required=True,
                       help="approved reviewer notes, at most 4000 characters")
    submit = commands.add_parser("submit", help="submit the prepared version and exact project build")
    for command in (upload, stage, submit):
        command.add_argument("--confirm", action="store_true", help="execute authorized mutations")
    args = parser.parse_args()
    version, build = release_identity()
    if args.command == "status":
        run(["asc", "review", "status", "--app", APP, "--platform", "IOS",
             "--version", args.version or version, "--pretty"], auth_env())
        return
    metadata = notes(version)
    if args.command == "plan":
        print(json.dumps({"app": APP, "version": version, "build": build,
                          "localizations": metadata, "steps": [
                              "tools/archive-ios.sh", "bash tools/appstore.sh upload --confirm",
                              "bash tools/appstore.sh stage --build-id <id> --review-notes <file> --confirm",
                              "bash tools/appstore.sh submit --confirm", "bash tools/appstore.sh status"]},
                         ensure_ascii=False, indent=2))
        return
    if not args.confirm:
        raise ValueError("mutation requires --confirm and owner authorization; use plan/status to inspect")
    if args.command == "upload":
        check_ipa(args.ipa, version, build)
        run(["asc", "builds", "upload", "--app", APP, "--ipa", str(args.ipa),
             "--version", version, "--build-number", build, "--wait"], auth_env())
        return
    env = auth_env()
    if args.command == "submit":
        current = run(["asc", "review", "status", "--app", APP, "--platform", "IOS",
                       "--version", version], env, True)
        if current["version"]["state"] not in ("PREPARE_FOR_SUBMISSION", "REJECTED", "DEVELOPER_REJECTED", "METADATA_REJECTED", "READY_FOR_REVIEW"):
            raise ValueError("version is not submittable; inspect status, do not resubmit an active review")
        run(["asc", "review", "submit", "--app", APP, "--platform", "IOS",
             "--version", version, "--build-number", build, "--confirm"], env)
        return
    review_notes = args.review_notes.read_text().strip()
    if not 0 < len(review_notes) <= 4000:
        raise ValueError("review notes must contain 1–4000 characters")
    # asc stage validates build ownership/version and resumes its own checkpoint.
    # Before any version mutation, verify the requested build matches this release.
    builds = run(["asc", "builds", "list", "--app", APP, "--platform", "IOS",
                  "--version", version, "--build-number", build, "--paginate"], env, True)
    if not any(b["id"] == args.build_id and b["attributes"]["processingState"] == "VALID"
               for b in builds["data"]):
        raise ValueError("build-id is not the VALID build for this app/version/build number")
    run(["asc", "versions", "create", "--app", APP, "--platform", "IOS",
         "--version", version, "--release-type", "AFTER_APPROVAL", "--if-exists", "skip"], env)
    current = run(["asc", "review", "status", "--app", APP, "--platform", "IOS",
                   "--version", version], env, True)
    if current["version"]["state"] not in ("PREPARE_FOR_SUBMISSION", "REJECTED", "DEVELOPER_REJECTED", "METADATA_REJECTED"):
        raise ValueError("version is not editable; inspect status, do not remove a live submission")
    detail = current.get("reviewDetailId")
    if not detail:
        raise ValueError("review contact/details missing; prepare them in App Store Connect first")
    run(["asc", "versions", "update", "--version-id", current["version"]["id"],
         "--release-type", "AFTER_APPROVAL"], env)
    run(["asc", "review", "details-update", "--id", detail, "--notes", review_notes], env)
    with tempfile.TemporaryDirectory(prefix="vibebuddy-asc-") as directory:
        location = Path(directory) / "version" / version
        location.mkdir(parents=True)
        for locale, value in metadata.items():
            (location / f"{locale}.json").write_text(json.dumps(value, ensure_ascii=False))
        checkpoint = ROOT / "VibeBuddyApp/build" / f"asc-stage-{version}-{build}.json"
        checkpoint.parent.mkdir(parents=True, exist_ok=True)
        run(["asc", "release", "stage", "--app", APP, "--platform", "IOS",
             "--version", version, "--build-id", args.build_id, "--metadata-dir", directory,
             "--checkpoint-file", str(checkpoint), "--confirm"], env)


if __name__ == "__main__":
    try:
        if not shutil.which("asc"):
            raise RuntimeError("install asc first: brew install asc")
        main()
    except (RuntimeError, ValueError, OSError, KeyError, zipfile.BadZipFile) as error:
        print(f"appstore: {error}", file=sys.stderr)
        sys.exit(1)

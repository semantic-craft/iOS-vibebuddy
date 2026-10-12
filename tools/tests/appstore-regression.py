#!/usr/bin/env python3
"""Critical release-boundary checks; never load real credentials or call Apple."""
import importlib.util
from pathlib import Path
import plistlib
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("appstore", Path(__file__).parents[1] / "appstore.py")
appstore = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appstore)


class ReleaseBoundaries(unittest.TestCase):
    def setUp(self):
        identity = patch.object(appstore, "release_identity", return_value=("1.3.38", "73"))
        notes = patch.object(appstore, "notes", return_value={"en-US": {"whatsNew": "Fixture"}})
        identity.start()
        notes.start()
        self.addCleanup(identity.stop)
        self.addCleanup(notes.stop)

    def test_wrong_ipa_is_rejected_before_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "wrong.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/App.app/Info.plist", plistlib.dumps({
                    "CFBundleIdentifier": "com.vibebuddy.app",
                    "CFBundleShortVersionString": "1.3.38", "CFBundleVersion": "72"}))
            with self.assertRaisesRegex(ValueError, "does not match"):
                appstore.check_ipa(ipa, "1.3.38", "73")

    def test_wrong_build_cannot_create_or_change_version(self):
        with tempfile.TemporaryDirectory() as directory:
            review = Path(directory) / "review.txt"
            review.write_text("Approved reviewer instructions")
            args = ["appstore.py", "stage", "--build-id", "wrong", "--review-notes", str(review), "--confirm"]
            with patch.object(sys, "argv", args), patch.object(appstore, "auth_env", return_value={}), \
                 patch.object(appstore, "run", return_value={"data": []}) as run:
                with self.assertRaisesRegex(ValueError, "not the VALID build"):
                    appstore.main()
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0][:3], ["asc", "builds", "list"])

    def test_missing_confirm_never_reads_credentials(self):
        with patch.object(sys, "argv", ["appstore.py", "submit"]), \
             patch.object(appstore, "auth_env", side_effect=AssertionError("must not read credentials")):
            with self.assertRaisesRegex(ValueError, "requires --confirm"):
                appstore.main()

    def test_active_review_cannot_be_resubmitted(self):
        with patch.object(sys, "argv", ["appstore.py", "submit", "--confirm"]), \
             patch.object(appstore, "auth_env", return_value={}), \
             patch.object(appstore, "run", return_value={"version": {"state": "WAITING_FOR_REVIEW"}}) as run:
            with self.assertRaisesRegex(ValueError, "do not resubmit"):
                appstore.main()
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][:3], ["asc", "review", "status"])

    def test_subcommand_help_needs_no_loader_or_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "asc"
            fake.write_text("#!/bin/sh\nexit 97\n")
            fake.chmod(0o755)
            env = dict(os.environ, HOME=directory, PATH=directory + os.pathsep + os.environ["PATH"])
            result = subprocess.run(["bash", str(appstore.ROOT / "tools/appstore.sh"), "upload", "--help"],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--ipa", result.stdout)
            result = subprocess.run(["bash", str(appstore.ROOT / "tools/appstore.sh"), "submit"],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("requires --confirm", result.stderr)
            self.assertNotIn("loader", result.stderr)

    def test_upload_does_not_require_release_notes(self):
        with patch.object(sys, "argv", ["appstore.py", "upload", "--confirm"]), \
             patch.object(appstore, "notes", side_effect=AssertionError("upload must not read notes")), \
             patch.object(appstore, "check_ipa"), patch.object(appstore, "auth_env", return_value={}), \
             patch.object(appstore, "run") as run:
            appstore.main()
            self.assertEqual(run.call_args.args[0][:3], ["asc", "builds", "upload"])

    def test_stage_active_review_never_mutates(self):
        with tempfile.TemporaryDirectory() as directory:
            review = Path(directory) / "notes.txt"
            review.write_text("Approved notes")
            replies = [{"data": [{"id": "right", "attributes": {"processingState": "VALID"}}]},
                       {"data": [{"id": "existing"}]}, {"version": {"state": "WAITING_FOR_REVIEW"}}]
            with patch.object(sys, "argv", ["appstore.py", "stage", "--build-id", "right", "--review-notes", str(review), "--confirm"]), \
                 patch.object(appstore, "auth_env", return_value={}), patch.object(appstore, "run", side_effect=replies) as run:
                with self.assertRaisesRegex(ValueError, "do not remove"):
                    appstore.main()
                self.assertEqual([c.args[0][:3] for c in run.call_args_list],
                                 [["asc", "builds", "list"], ["asc", "versions", "list"], ["asc", "review", "status"]])

    def test_asc_profile_and_foreign_secrets_are_not_combined(self):
        with patch.dict(appstore.os.environ, {"ASC_KEY_ID": "fixture", "ASC_ISSUER_ID": "fixture",
                          "ASC_PRIVATE_KEY_B64": "Zml4dHVyZQ==", "ASC_PROFILE": "other",
                          "ASC_PRIVATE_KEY_PATH": "/other/key", "ASC_PRIVATE_KEY": "other"}, clear=True):
            env = appstore.auth_env()
            self.assertNotIn("ASC_PROFILE", env)
            self.assertNotIn("ASC_PRIVATE_KEY_PATH", env)
            self.assertNotIn("ASC_PRIVATE_KEY", env)


if __name__ == "__main__":
    unittest.main()

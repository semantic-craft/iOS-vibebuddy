#!/usr/bin/env python3
"""Critical release-boundary checks; never load real credentials or call Apple."""
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("appstore", Path(__file__).parents[1] / "appstore.py")
appstore = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appstore)


class ReleaseBoundaries(unittest.TestCase):
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

"""Release contract fixtures. The optional macOS round trip uses Sparkle's own signing tool."""
import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import publish_release
import sparkle_release as sparkle
from test_publish_release import FakeGitHub, release_fixture

TAG = "v1.16.0"
BUILD = "72"
MINIMUM = "15.4"
CHANGELOG = """## 1.16.0 — 2026-11-26

### English

![WallpaperMachine 1.16.0](Resources/ReleaseBanners/1.16.0.jpg)

- Display <text> & [labels](https://example.org).

### 简体中文

- 显示文字和标签。

### 한국어

- 텍스트와 레이블을 표시합니다.
"""
SIGNER = Path(os.environ.get("SPARKLE_TEST_SIGN_UPDATE", sparkle.SIGN_UPDATE))


class SparkleReleaseTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        seed = os.urandom(32)
        self.private = base64.b64encode(seed).decode()
        public = subprocess.run(["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
                                input=sparkle.PKCS8 + seed, capture_output=True, check=True).stdout
        self.public = base64.b64encode(public[-32:]).decode()
        self.archive = self.root / "WallpaperMachine-1.16.0-arm64.zip"
        self.feed = self.root / "appcast.xml"
        self.info = {
            "CFBundleIdentifier": "app.wallpapermachine", "CFBundleShortVersionString": TAG[1:],
            "CFBundleVersion": BUILD, "LSMinimumSystemVersion": MINIMUM, "SUPublicEDKey": self.public,
            "SUFeedURL": sparkle.FEED_URL, "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
            "SUEnableAutomaticChecks": False, "SUAllowsAutomaticUpdates": False,
            "SUSignedFeedFailureExpirationInterval": 0,
        }
        self.notes = sparkle.descriptions(CHANGELOG, TAG)
        self.write_archive()

    def write_archive(self):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("WallpaperMachine.app/Contents/Info.plist", plistlib.dumps(self.info))
            archive.writestr("WallpaperMachine.app/Contents/Resources/sample", b"sample resource")

    def openssl_sign(self, path, private_key, signer):
        key = self.root / "fixture-key.der"
        key.write_bytes(sparkle.PKCS8 + base64.b64decode(private_key))
        result = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", key, "-keyform", "DER", "-rawin", "-in", path],
                                capture_output=True, check=True)
        signature = base64.b64encode(result.stdout).decode()
        if path.suffix == ".xml":
            length = path.stat().st_size
            with path.open("ab") as feed:
                feed.write(f"<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {length}\n-->\n".encode())
        return signature

    def write_feed(self):
        with mock.patch.object(sparkle, "sign", self.openssl_sign):
            sparkle.write_feed(self.archive, self.feed, TAG, BUILD, self.public, self.private, self.notes)

    def verify(self):
        sparkle.verify(self.archive, self.feed, TAG, BUILD, self.public, MINIMUM, self.notes)

    def test_preflight_rejects_missing_malformed_and_mismatched_keys_without_printing_them(self):
        sparkle.check_keys(self.public, self.private)
        for public, private in [("", self.private), (self.public, ""), (self.public, "not base64"),
                                (self.public, base64.b64encode(os.urandom(32)).decode())]:
            with self.assertRaises(sparkle.SparkleError) as failed:
                sparkle.check_keys(public, private)
            self.assertFalse(private and private in str(failed.exception))

    def test_only_a_source_predating_sparkle_can_use_the_legacy_asset_set(self):
        project = self.root / "project.yml"
        project.write_text(f'MARKETING_VERSION: "{TAG[1:]}"\nCURRENT_PROJECT_VERSION: "{BUILD}"\n')
        self.assertIsNone(sparkle.project_build(TAG, project))
        script = self.root / "scripts/sparkle_release.py"
        script.parent.mkdir()
        script.touch()
        with self.assertRaises(sparkle.SparkleError):
            sparkle.project_build(TAG, project)
        info = self.root / "App/Resources/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"SUFeedURL": ""}))
        self.assertEqual(sparkle.project_build(TAG, project), BUILD)

    def test_version_build_feed_trust_and_floor_are_read_from_the_archived_bundle(self):
        for key, wrong in {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
                           "CFBundleIdentifier": "another.app", "LSMinimumSystemVersion": "",
                           "SUFeedURL": "https://untrusted.invalid/feed", "SUPublicEDKey": "",
                           "SUEnableAutomaticChecks": True, "SUAllowsAutomaticUpdates": True,
                           "SURequireSignedFeed": False, "SUVerifyUpdateBeforeExtraction": False,
                           "SUSignedFeedFailureExpirationInterval": False}.items():
            with self.subTest(key=key), mock.patch.dict(self.info, {key: wrong}):
                self.write_archive()
                with self.assertRaises(sparkle.SparkleError):
                    self.write_feed()
                self.assertFalse(self.feed.exists())

    def test_signed_feed_names_the_immutable_zip_and_contains_only_plaintext_localizations(self):
        self.write_feed()
        self.verify()
        item = ET.parse(self.feed).find("channel/item")
        self.assertEqual(item.findtext(sparkle.SPARKLE + "minimumSystemVersion"), "15.4")
        self.assertEqual(item.findtext(sparkle.SPARKLE + "version"), BUILD)
        self.assertEqual(item.findtext(sparkle.SPARKLE + "shortVersionString"), "1.16.0")
        self.assertEqual(item.find("enclosure").get("url"),
                         "https://github.com/MMFoundation/WallpaperMachine/releases/download/v1.16.0/WallpaperMachine-1.16.0-arm64.zip")
        notes = item.findall("description")
        self.assertEqual([n.get(sparkle.LANG) for n in notes], ["en", "zh-Hans", "ko"])
        self.assertEqual(notes[0].text, "- Display <text> & labels.")
        self.assertTrue(all(n.get(sparkle.SPARKLE + "format") == "plain-text" for n in notes))

    def test_unsigned_or_modified_feed_and_same_size_archive_tampering_are_rejected(self):
        self.write_feed()
        feed = self.feed.read_bytes()
        for corrupt in (feed[:sparkle.SIGNATURE_BLOCK.search(feed).start()],
                        feed.replace(b"<title>WallpaperMachine Updates", b"<title>WallpaperMachine updates"),
                        feed + b"extra unsigned text"):
            self.feed.write_bytes(corrupt)
            with self.assertRaises(sparkle.SparkleError):
                self.verify()
        self.feed.write_bytes(feed)
        self.archive.write_bytes(self.archive.read_bytes().replace(b"sample resource", b"altered content"))
        with self.assertRaisesRegex(sparkle.SparkleError, "signature"):
            self.verify()

    def test_new_publication_preflights_all_five_assets_before_github_and_verifies_the_draft(self):
        notes, legacy_assets = release_fixture(self.root, TAG)
        project = self.root / "project.yml"
        project.write_text(f'Sparkle:\n  exactVersion: 2.10.0\nMARKETING_VERSION: "{TAG[1:]}"\nCURRENT_PROJECT_VERSION: "{BUILD}"\n')
        manifest = Path(legacy_assets[-1])
        value = json.loads(manifest.read_text())
        value["assets"][0]["browser_download_url"] = f"{sparkle.REPOSITORY}/releases/download/{TAG}/{Path(legacy_assets[0]).name}"
        value.update(changelog=CHANGELOG, minimum_system_version=MINIMUM)
        manifest.write_text(json.dumps(value))
        self.write_feed()
        assets = [*legacy_assets, str(self.archive), str(self.feed)]
        github = FakeGitHub()

        def publish(files, key):
            return publish_release.publish(TAG, notes, files, run=github, project=project, sparkle_public_key=key)

        for files, key in [(legacy_assets, self.public), (assets[:-1], self.public), (assets, "")]:
            with self.assertRaises(publish_release.PublishError):
                publish(files, key)
        self.assertFalse(github.calls)
        action, latest = publish(assets, self.public)
        self.assertEqual((action, latest), (publish_release.CREATE, True))
        self.assertEqual({entry["name"] for entry in github.uploaded}, {Path(path).name for path in assets})
        self.assertIn("--draft=false", github.mutations[-1])

    @unittest.skipUnless(sys.platform == "darwin" and SIGNER.is_file(),
                         "set SPARKLE_TEST_SIGN_UPDATE to the resolved macOS Sparkle 2.10 binary")
    def test_signatures_and_signed_xml_round_trip_through_sparkles_own_tool_without_a_keychain(self):
        sparkle.write_feed(self.archive, self.feed, TAG, BUILD, self.public, self.private, self.notes, SIGNER)
        self.verify()
        signature = ET.parse(self.feed).find("channel/item/enclosure").get(sparkle.SPARKLE + "edSignature")
        for args in ([self.archive, signature], [self.feed]):
            subprocess.run([SIGNER, "--ed-key-file", "-", "--verify", *args],
                           input=self.private + "\n", text=True, capture_output=True, check=True)


if __name__ == "__main__":
    unittest.main()

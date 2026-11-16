#!/usr/bin/env python3
"""Tests for advancing the published Nix release without downgrades or hash changes."""
from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import update_nix_release


class GitHubContents:
    def __init__(self, pin, concurrent_pin=None, failure=None):
        self.pin = pin
        self.concurrent_pin = concurrent_pin
        self.failure = failure
        self.revision = 1
        self.writes = 0

    def __call__(self, command, **kwargs):
        if "PUT" not in command:
            entry = {"sha": str(self.revision),
                     "content": base64.b64encode(json.dumps(self.pin).encode()).decode()}
            return subprocess.CompletedProcess(command, 0, json.dumps(entry), "")
        self.writes += 1
        request = json.loads(kwargs["input"])
        if self.failure:
            return subprocess.CompletedProcess(command, 1, "", self.failure)
        if self.concurrent_pin is not None:
            self.pin = self.concurrent_pin
            self.concurrent_pin = None
            self.revision += 1
        if request["sha"] != str(self.revision):
            return subprocess.CompletedProcess(command, 1, "", "gh: conflict (HTTP 409)")
        if request["branch"] != "main":
            raise AssertionError(request)
        self.pin = json.loads(base64.b64decode(request["content"]))
        self.revision += 1
        return subprocess.CompletedProcess(command, 0, "{}", "")


class UpdateNixReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.image = Path(self.temporary.name) / "WallpaperMachine-1.12.1-arm64.dmg"
        self.image.write_bytes(b"published disk image")
        self.pin = update_nix_release.release_pin("v1.12.1", self.image)

    def test_pin_uses_the_published_image_bytes(self):
        expected_hash = base64.b64encode(hashlib.sha256(self.image.read_bytes()).digest()).decode()
        self.assertEqual(self.pin, {"version": "1.12.1", "hash": "sha256-" + expected_hash})

    def test_publication_advances_both_version_and_hash(self):
        remote = GitHubContents({"version": "1.12.0", "hash": "old"})
        self.assertTrue(update_nix_release.update_pin("owner/repo", self.pin, remote))
        self.assertEqual(remote.pin, self.pin)

    def test_older_release_finishing_late_cannot_downgrade_the_pin(self):
        newer = {"version": "1.13.0", "hash": "newer"}
        remote = GitHubContents(newer)
        self.assertFalse(update_nix_release.update_pin("owner/repo", self.pin, remote))
        self.assertEqual(remote.pin, newer)
        self.assertEqual(remote.writes, 0)

    def test_an_identical_pin_is_idempotent(self):
        remote = GitHubContents(self.pin)
        self.assertFalse(update_nix_release.update_pin("owner/repo", self.pin, remote))
        self.assertEqual(remote.writes, 0)

    def test_a_released_versions_hash_cannot_be_replaced(self):
        original = {**self.pin, "hash": "original"}
        remote = GitHubContents(original)
        with self.assertRaisesRegex(ValueError, "different hash"):
            update_nix_release.update_pin("owner/repo", self.pin, remote)
        self.assertEqual(remote.pin, original)
        self.assertEqual(remote.writes, 0)

    def test_a_concurrent_newer_pin_is_rechecked_after_conflict(self):
        newer = {"version": "1.13.0", "hash": "newer"}
        remote = GitHubContents({"version": "1.11.0", "hash": "old"}, concurrent_pin=newer)
        self.assertFalse(update_nix_release.update_pin("owner/repo", self.pin, remote))
        self.assertEqual(remote.pin, newer)
        self.assertEqual(remote.writes, 1)

    def test_a_concurrent_older_pin_still_advances(self):
        remote = GitHubContents({"version": "1.11.0", "hash": "old"},
                                concurrent_pin={"version": "1.12.0", "hash": "intermediate"})
        self.assertTrue(update_nix_release.update_pin("owner/repo", self.pin, remote))
        self.assertEqual(remote.pin, self.pin)
        self.assertEqual(remote.writes, 2)

    def test_remote_failures_are_not_reported_as_success(self):
        remote = GitHubContents({"version": "1.12.0", "hash": "old"}, failure="gh: forbidden (HTTP 403)")
        with self.assertRaisesRegex(RuntimeError, "forbidden"):
            update_nix_release.update_pin("owner/repo", self.pin, remote)
        self.assertEqual(remote.writes, 1)

    def test_conflict_retries_are_bounded(self):
        remote = GitHubContents({"version": "1.12.0", "hash": "old"}, failure="gh: conflict (HTTP 409)")
        with self.assertRaisesRegex(RuntimeError, "conflict"):
            update_nix_release.update_pin("owner/repo", self.pin, remote)
        self.assertEqual(remote.writes, 3)

    def test_malformed_current_version_is_not_overwritten(self):
        remote = GitHubContents({"version": "broken", "hash": "old"})
        with self.assertRaisesRegex(ValueError, "valid version"):
            update_nix_release.update_pin("owner/repo", self.pin, remote)
        self.assertEqual(remote.writes, 0)

    def test_mismatched_image_and_tag_are_rejected(self):
        for tag in ("1.12.1", "v1.12.1-beta", "v1.12.2"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                update_nix_release.release_pin(tag, self.image)

    def test_invalid_repository_is_rejected_before_a_request(self):
        remote = GitHubContents({"version": "1.12.0", "hash": "old"})
        with self.assertRaises(ValueError):
            update_nix_release.update_pin("owner/repo?ref=other", self.pin, remote)


if __name__ == "__main__":
    unittest.main()

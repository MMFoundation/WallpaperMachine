#!/usr/bin/env python3
"""Advance the Nix release pin on main after publishing a verified disk image."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from lib.dmg import image_name
from lib.glyphs import markers
from publish_release import version_key

PIN_PATH = "nix/release.json"
MARK = markers()


def release_pin(tag, image):
    match = re.fullmatch(r"v(\d+\.\d+\.\d+)", tag)
    if not match:
        raise ValueError(f"Not a release tag: {tag!r}")
    version = match.group(1)
    image = Path(image)
    if image.name != image_name(version):
        raise ValueError(f"The image does not belong to {tag}: {image.name}")
    with image.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").digest()
    return {"version": version, "hash": "sha256-" + base64.b64encode(digest).decode()}


def update_pin(repository, pin, run=subprocess.run):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError(f"Not an owner/name repository: {repository!r}")
    endpoint = f"repos/{repository}/contents/{PIN_PATH}"
    for attempt in range(3):
        response = run(["gh", "api", endpoint + "?ref=main"],
                       check=True, capture_output=True, text=True)
        entry = json.loads(response.stdout)
        current = json.loads(base64.b64decode(entry["content"]))
        current_version = version_key(current.get("version"))
        if current_version is None:
            raise ValueError("The current Nix release pin has no valid version.")
        if current_version > version_key(pin["version"]):
            return False
        if current_version == version_key(pin["version"]):
            if current != pin:
                raise ValueError("The same Nix release version already has a different hash.")
            return False
        request = {
            "message": f"chore(nix): track release v{pin['version']}",
            "branch": "main",
            "sha": entry["sha"],
            "content": base64.b64encode((json.dumps(pin, indent=2) + "\n").encode()).decode(),
        }
        response = run(["gh", "api", "--method", "PUT", endpoint, "--input", "-"],
                       input=json.dumps(request), capture_output=True, text=True)
        if response.returncode == 0:
            return True
        if "(HTTP 409)" not in response.stderr or attempt == 2:
            raise RuntimeError(f"Cannot update the Nix release pin: {response.stderr.strip()}")
    return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="The published release tag, like v1.2.3.")
    parser.add_argument("--repository", required=True, help="GitHub repository as owner/name.")
    parser.add_argument("image", type=Path, help="The verified disk image uploaded by the publish job.")
    args = parser.parse_args(argv)
    pin = release_pin(args.tag, args.image)
    changed = update_pin(args.repository, pin)
    print(f"{MARK.ok} Nix release pin {'advanced to' if changed else 'already at or beyond'} {args.tag}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)

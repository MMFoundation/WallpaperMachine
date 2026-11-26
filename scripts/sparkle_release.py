#!/usr/bin/env python3
"""Sign the Sparkle ZIP and appcast, or check the release keys before building.

Only the macOS build job signs. The Linux publisher calls verify() with its own
copy of the repository's public key before making any change to GitHub.
"""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from xml.parsers.expat import ExpatError
import zipfile

import bump_version
from lib.bundle_contract import APP_IDENTIFIER
from lib.paths import BUILD, PROJECT_YML
import release_notes

PUBLIC_KEY = "WALLPAPER_MACHINE_SPARKLE_PUBLIC_KEY"
PRIVATE_KEY = "WALLPAPER_MACHINE_SPARKLE_PRIVATE_KEY"
FEED_URL = "https://www.wallpapermachine.app/updates/appcast"
REPOSITORY = "https://github.com/MMFoundation/WallpaperMachine"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
LANG = "{http://www.w3.org/XML/1998/namespace}lang"
SIGN_UPDATE = BUILD / "SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
SPKI = bytes.fromhex("302a300506032b6570032100")
PKCS8 = bytes.fromhex("302e020100300506032b657004220420")
SIGNATURE_BLOCK = re.compile(rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n?\Z")
LANGUAGES = {"english": "en", "chinese": "zh-Hans", "korean": "ko"}


class SparkleError(ValueError):
    """An unsafe or incomplete update; never include private key data in the message."""


def decoded(value, size, name):
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        data = b""
    if len(data) != size:
        raise SparkleError(f"{name} must be a base64-encoded {size}-byte value.")
    return data


def check_keys(public_key, private_key):
    public = decoded(public_key, 32, PUBLIC_KEY)
    seed = decoded(private_key, 32, PRIVATE_KEY)
    result = subprocess.run(["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
                            input=PKCS8 + seed, capture_output=True)
    if result.returncode:
        raise SparkleError("OpenSSL could not derive the Ed25519 public key; use OpenSSL 3.")
    if result.stdout != SPKI + public:
        raise SparkleError("The WallpaperMachine Sparkle private key does not match its public key.")


def project_build(tag, project=PROJECT_YML):
    """Use the checked-out tag's build settings, never a missing asset or key, to recognize a legacy release."""
    source = project.read_text(encoding="utf-8")
    version, build = bump_version.read_yml_versions(source)
    if tag != f"v{version}" or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise SparkleError(f"{tag} does not match a valid version and build in project.yml.")
    if "Sparkle" in source or "WALLPAPER_MACHINE_UPDATE_FEED" in source:
        return build
    info = project.parent / "App/Resources/Info.plist"
    if info.is_file() and {"SUFeedURL", "SUPublicEDKey"}.intersection(plistlib.loads(info.read_bytes())):
        return build
    if (project.parent / "scripts/sparkle_release.py").is_file():
        raise SparkleError("The tagged project contains the Sparkle release tooling but no update configuration.")
    return None


def archive_info(archive, tag, build, public_key):
    name = f"WallpaperMachine-{tag[1:]}-arm64.zip"
    if archive.name != name:
        raise SparkleError(f"The update archive must be named {name}.")
    with zipfile.ZipFile(archive) as bundle:
        plist = "WallpaperMachine.app/Contents/Info.plist"
        if bundle.namelist().count(plist) != 1:
            raise SparkleError(f"The ZIP must contain exactly one {plist}.")
        info = plistlib.loads(bundle.read(plist))
    expected = {
        "CFBundleIdentifier": APP_IDENTIFIER,
        "CFBundleShortVersionString": tag[1:],
        "CFBundleVersion": build,
        "SUFeedURL": FEED_URL,
        "SUPublicEDKey": public_key,
        "SUEnableAutomaticChecks": False,
        "SUAllowsAutomaticUpdates": False,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
        "SUSignedFeedFailureExpirationInterval": 0,
    }
    for key, value in expected.items():
        if type(info.get(key)) is not type(value) or info[key] != value:
            raise SparkleError(f"The archived application's {key} does not match the release configuration.")
    minimum = info.get("LSMinimumSystemVersion")
    if not isinstance(minimum, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", minimum):
        raise SparkleError("The archived application has no valid minimum macOS version.")
    return minimum


def descriptions(changelog, tag):
    body = release_notes.recorded_notes(changelog, tag)
    if body is None:
        raise SparkleError(f"No release notes for {tag}.")
    release_notes.require_localized_notes(body, tag)
    result = {}
    for language, block in release_notes.language_blocks(body).items():
        lines = [line.removeprefix("#### ") for line in block.splitlines()
                 if not release_notes.BANNER.fullmatch(line) and not line.startswith("**Full changelog**")]
        text = re.sub(r"\[([^]\n]+)\]\([^()\n]+\)", r"\1", "\n".join(lines)).strip()
        result[LANGUAGES[language]] = text
    return result


def sign(path, private_key, signer):
    result = subprocess.run([signer, "--ed-key-file", "-", "-p", path], input=private_key + "\n",
                            capture_output=True, text=True)
    if result.returncode:
        raise SparkleError(f"Sparkle could not sign {path.name}.")
    return result.stdout.strip()


def write_feed(archive, feed, tag, build, public_key, private_key, notes, signer=SIGN_UPDATE):
    minimum = archive_info(archive, tag, build, public_key)
    signature = sign(archive, private_key, signer)
    ET.register_namespace("sparkle", SPARKLE[1:-1])
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "WallpaperMachine Updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"WallpaperMachine {tag[1:]}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, SPARKLE + "version").text = build
    ET.SubElement(item, SPARKLE + "shortVersionString").text = tag[1:]
    ET.SubElement(item, SPARKLE + "minimumSystemVersion").text = minimum
    ET.SubElement(item, SPARKLE + "hardwareRequirements").text = "arm64"
    for language, text in notes.items():
        ET.SubElement(item, "description", {LANG: language, SPARKLE + "format": "plain-text"}).text = text
    ET.SubElement(item, "enclosure", {SPARKLE + "edSignature": signature, "type": "application/octet-stream",
                                     "url": f"{REPOSITORY}/releases/download/{tag}/{archive.name}",
                                     "length": str(archive.stat().st_size)})
    ET.indent(rss)
    with tempfile.TemporaryDirectory(dir=feed.parent) as directory:
        signed = Path(directory) / "appcast.xml"
        ET.ElementTree(rss).write(signed, encoding="utf-8", xml_declaration=True)
        sign(signed, private_key, signer)
        verify(archive, signed, tag, build, public_key, minimum, notes)
        signed.replace(feed)


def verify(archive, feed, tag, build, public_key, minimum, notes):
    """Verify both signatures with the pinned public key, then compare signed metadata."""
    public = decoded(public_key, 32, PUBLIC_KEY)
    content = feed.read_bytes()
    block = SIGNATURE_BLOCK.search(content)
    if not block or block.start() != int(block[2]):
        raise SparkleError("Missing Sparkle feed signature or incorrect signed byte length.")
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        key, data, sig = root / "public.der", root / "feed.xml", root / "signature"
        key.write_bytes(SPKI + public)
        data.write_bytes(content[:block.start()])

        def verify_bytes(path, signature):
            sig.write_bytes(decoded(signature, 64, "Sparkle signature"))
            result = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", key,
                                     "-rawin", "-in", path, "-sigfile", sig], capture_output=True)
            if result.returncode:
                raise SparkleError(f"Invalid Ed25519 signature for {path.name}.")

        verify_bytes(data, block[1])
        rss = ET.parse(data).getroot()
        items = rss.findall("./channel/item")
        if rss.tag != "rss" or len(items) != 1 or len(items[0].findall("enclosure")) != 1:
            raise SparkleError("The signed appcast must describe exactly one update ZIP.")
        item = items[0]
        inline = item.findall("description")
        if (len(inline) != len(notes) or {d.get(LANG): d.text for d in inline} != notes
                or any(d.get(SPARKLE + "format") != "plain-text" or len(d) for d in inline)
                or item.find(SPARKLE + "releaseNotesLink") is not None
                or item.find(SPARKLE + "fullReleaseNotesLink") is not None):
            raise SparkleError("The signed appcast must embed the release's localized plain-text notes.")
        enclosure = item.find("enclosure")
        if (item.findtext(SPARKLE + "version") != build or item.findtext(SPARKLE + "shortVersionString") != tag[1:]
                or item.findtext(SPARKLE + "minimumSystemVersion") != minimum
                or item.findtext(SPARKLE + "hardwareRequirements") != "arm64"
                or enclosure.get("url") != f"{REPOSITORY}/releases/download/{tag}/{archive.name}"
                or enclosure.get("length") != str(archive.stat().st_size)):
            raise SparkleError("The signed appcast does not match the official release ZIP or bundle metadata.")
        verify_bytes(archive, enclosure.get(SPARKLE + "edSignature"))
    if archive_info(archive, tag, build, public_key) != minimum:
        raise SparkleError("The ZIP and disk image disagree on the minimum macOS version.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("preflight").add_argument("--tag", required=True)
    create = commands.add_parser("sign")
    create.add_argument("--tag", required=True)
    create.add_argument("--archive", type=Path, required=True)
    create.add_argument("--output", type=Path, required=True)
    notes = create.add_mutually_exclusive_group(required=True)
    notes.add_argument("--changelog", type=Path)
    notes.add_argument("--rehearsal", action="store_true", help="Sign a rehearsal feed without release notes.")
    args = parser.parse_args()
    public_key = os.getenv(PUBLIC_KEY, "")
    private_key = os.environ.pop(PRIVATE_KEY, "").strip()
    build = project_build(args.tag)
    if build is None:
        raise SparkleError("The release project has no Sparkle update configuration.")
    check_keys(public_key, private_key)
    if args.command == "sign":
        write_feed(args.archive, args.output, args.tag, build, public_key, private_key,
                   {} if args.rehearsal else descriptions(args.changelog.read_text(encoding="utf-8"), args.tag))
    print(f"Sparkle {args.command} passed for {args.tag} ({build}).")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, ExpatError, ET.ParseError, zipfile.BadZipFile,
            release_notes.NotesError, bump_version.VersionError) as error:
        sys.exit(f"Sparkle update failed: {error}")

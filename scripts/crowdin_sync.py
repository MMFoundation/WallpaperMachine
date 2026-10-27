#!/usr/bin/env python3
"""Sync the string catalogs with Crowdin: push the keys and translations, pull translations back.

    python3 scripts/crowdin_sync.py push               # source strings, then the catalogs' translations
    python3 scripts/crowdin_sync.py push --overwrite   # ... approved, so they replace Crowdin's where they differ
    python3 scripts/crowdin_sync.py pull               # write Crowdin's translations into the catalogs
    python3 scripts/crowdin_sync.py pull --dry-run     # report what would change, write nothing

The English keys are the source; the catalogs stay the file the app builds from. `push` sends
the keys and the catalogs' translations as unapproved translations: a value Crowdin already
has is not added again and an approved translation is never replaced, so an ordinary merge
cannot undo a translator's approved work. `--overwrite` approves the catalogs' translations
instead, the deliberate way to make Crowdin take a correction made in the repository; it also
discards every Crowdin edit not pulled yet. `pull` rewrites only the `value` of a translation
that is already in a catalog, for the languages `AppLanguage.supported` registers, and only
when Crowdin has it translated and it still reads as a valid format string. Every other byte,
including the catalogs' mixed one-line layout, stays as it was. A language Crowdin has and the
app does not ship is ignored. Needs the Crowdin CLI (`npm install -g @crowdin/cli`) signed in
with `crowdin login` or given CROWDIN_PERSONAL_TOKEN. The Crowdin workflow
(.github/workflows/crowdin.yml) runs both; docs/localization.md describes the whole loop.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from json.decoder import scanstring
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from lib.glyphs import markers
from lib.localization import SOURCE_LANGUAGE, swift_languages, translation_problem
from lib.paths import ROOT

MARK = markers()
CONFIG = ROOT / "crowdin.yml"
CATALOGS = (
    ROOT / "App/Resources/Localizable.xcstrings",
    ROOT / "App/Resources/InfoPlist.xcstrings",
    ROOT / "Extension/Localizable.xcstrings",
)
INSTALL = "npm install -g @crowdin/cli"
SHOWN = 12

WHITESPACE = re.compile(r"\s*")
LITERAL = re.compile(r"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null")


def value_spans(text: str) -> dict[tuple[str, str], tuple[int, int]]:
    """Where each translation's `value` string literal sits in a catalog's text.

    Keyed by (string key, language). A catalog is rewritten in place at these offsets, so
    its layout survives; re-serialising the JSON would reflow every entry.
    """
    spans: dict[tuple[str, str], tuple[int, int]] = {}

    def skip(i: int) -> int:
        return WHITESPACE.match(text, i).end()

    def walk(i: int, path: tuple[str, ...]) -> int:
        i = skip(i)
        char = text[i]
        if char == "{":
            i = skip(i + 1)
            if text[i] == "}":
                return i + 1
            while True:
                key, i = scanstring(text, skip(i) + 1)
                i = walk(skip(i) + 1, path + (key,))
                i = skip(i)
                if text[i] == ",":
                    i += 1
                    continue
                if text[i] == "}":
                    return i + 1
                raise ValueError(f"expected ',' or '}}' at offset {i}")
        if char == "[":
            i = skip(i + 1)
            if text[i] == "]":
                return i + 1
            while True:
                i = skip(walk(i, path + ("[]",)))
                if text[i] == ",":
                    i += 1
                    continue
                if text[i] == "]":
                    return i + 1
                raise ValueError(f"expected ',' or ']' at offset {i}")
        if char == '"':
            _, end = scanstring(text, i + 1)
            if len(path) == 6 and path[::2] == ("strings", "localizations", "stringUnit") and path[5] == "value":
                spans[(path[1], path[3])] = (i, end)
            return end
        literal = LITERAL.match(text, i)
        if not literal:
            raise ValueError(f"unexpected character at offset {i}")
        return literal.end()

    walk(0, ())
    return spans


def merge(repo_text: str, crowdin_text: str, languages: list[str]):
    """The catalog text with Crowdin's translations applied, and what was changed or refused.

    Returns (text, changed, refused): `changed` counts the units rewritten per language;
    `refused` lists (language, key, reason) for translations that would break the format.
    """
    repo = json.loads(repo_text)
    crowdin = json.loads(crowdin_text)
    spans = value_spans(repo_text)
    edits: list[tuple[int, int, str]] = []
    changed: Counter = Counter()
    refused: list[tuple[str, str, str]] = []
    for key, entry in repo["strings"].items():
        theirs = crowdin["strings"].get(key, {}).get("localizations", {})
        for language in languages:
            ours = entry.get("localizations", {}).get(language, {}).get("stringUnit")
            unit = theirs.get(language, {}).get("stringUnit")
            # An untranslated unit comes back in the `new` state, filled with the English text.
            if not ours or not unit or unit.get("state") != "translated":
                continue
            value = unit.get("value", "")
            if value == ours.get("value"):
                continue
            problem = translation_problem(key, value)
            if problem:
                refused.append((language, key, problem))
                continue
            start, end = spans[(key, language)]
            edits.append((start, end, json.dumps(value, ensure_ascii=False)))
            changed[language] += 1
    text = repo_text
    for start, end, replacement in sorted(edits, reverse=True):
        text = text[:start] + replacement + text[end:]
    return text, changed, refused


def crowdin_cli(*arguments: str, base_path: Path | None = None) -> int:
    """Run the Crowdin CLI with this repository's config; its output shows only when it fails."""
    cli = shutil.which("crowdin")
    if not cli:
        print(f"{MARK.missing} the Crowdin CLI is not installed: {INSTALL}")
        return 1
    command = [cli, *arguments, "-c", str(CONFIG), "--no-colors", "--no-progress"]
    if base_path:
        command += ["--base-path", str(base_path)]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        print(result.stdout + result.stderr, end="")
        print(f"{MARK.missing} crowdin {' '.join(arguments)} failed ({result.returncode})")
    return result.returncode


def push(overwrite: bool, dry_run: bool) -> int:
    dry = ["--dryrun"] if dry_run else []
    steps = [
        ("source strings", ["upload", "sources", *dry]),
        ("translations" + (" (approved, overwriting Crowdin's)" if overwrite else ""),
         ["upload", "translations", "--import-eq-suggestions", *(["--auto-approve-imported"] if overwrite else []), *dry]),
    ]
    for label, arguments in steps:
        print(f"{MARK.step} pushing {label}")
        if crowdin_cli(*arguments):
            return 1
    print(f"{MARK.ok} pushed{' (dry run)' if dry_run else ''}")
    return 0


def pull(dry_run: bool) -> int:
    languages = [tag for tag in swift_languages() if tag != SOURCE_LANGUAGE]
    with tempfile.TemporaryDirectory(prefix="crowdin-pull-") as scratch:
        # Crowdin writes the downloaded catalogs over their sources, so it works on copies.
        for catalog in CATALOGS:
            target = Path(scratch) / catalog.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(catalog, target)
        print(f"{MARK.step} pulling translations")
        if crowdin_cli("download", base_path=Path(scratch)):
            return 1
        total: Counter = Counter()
        refused: list[tuple[str, str, str, str]] = []
        for catalog in CATALOGS:
            name = str(catalog.relative_to(ROOT))
            text, changed, rejected = merge(catalog.read_text(), (Path(scratch) / catalog.relative_to(ROOT)).read_text(), languages)
            total.update(changed)
            refused += [(name, *item) for item in rejected]
            if changed and not dry_run:
                catalog.write_text(text)
            if changed:
                print(f"{MARK.ok} {name}: " + ", ".join(f"{language} {count}" for language, count in sorted(changed.items())))
    if not total:
        print(f"{MARK.ok} the catalogs already match Crowdin")
    else:
        print(f"{MARK.ok} {sum(total.values())} translation(s) {'would change' if dry_run else 'updated'}")
    for name, language, key, reason in refused[:SHOWN]:
        print(f"{MARK.warn} {name}: {language} translation of {key!r} {reason}; kept the catalog's")
    if len(refused) > SHOWN:
        print(f"{MARK.warn} ... and {len(refused) - SHOWN} more refused")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    pushing = commands.add_parser("push", help="send the catalogs' keys and translations to Crowdin")
    pushing.add_argument("--overwrite", action="store_true",
                         help="replace translations Crowdin already has with the catalogs' (a maintainer's correction)")
    pushing.add_argument("--dry-run", action="store_true", help="ask the CLI what it would send, send nothing")
    pulling = commands.add_parser("pull", help="write Crowdin's translations into the catalogs")
    pulling.add_argument("--dry-run", action="store_true", help="report the changes, write nothing")
    args = parser.parse_args()
    if args.command == "push":
        return push(args.overwrite, args.dry_run)
    return pull(args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())

"""Guard the repository's own Markdown links: every relative link names a file that exists, and
every `#anchor` names a heading (or an explicit `<a id>`) of the page it points at.

GitHub derives a heading's anchor from its rendered text: lowercased, punctuation and symbols
removed, each space a hyphen, and `-1`, `-2` … appended to repeats. A link whose heading was
renamed still opens the page, at the top, so nothing shows it is broken. External links,
links inside code and anchors into files other than Markdown are out of scope. The archives are
history and are not checked, though a current page may link into them.
"""
from collections import Counter
from pathlib import Path
import re
import subprocess
import tempfile
import unicodedata
import unittest
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[2]
UNCHECKED = ("docs/archive/", "docs/testing/archive/", "ThirdParty/")
SHOWN = 12

FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
COMMENT = re.compile(r"<!--.*?-->", re.S)
INLINE_CODE = re.compile(r"(`+)(.+?)\1")
# `[text](target)` and `![alt](target)`, the target without its optional title.
MARKDOWN_LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
HTML_LINK = re.compile(r"""<(?:a|img)\b[^>]*?\b(?:href|src)\s*=\s*["']([^"']+)["']""", re.I)
EXPLICIT_ANCHOR = re.compile(r"""<a\b[^>]*?\b(?:id|name)\s*=\s*["']([^"']+)["']""", re.I)


def markdown_files():
    listed = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.split("\n")
    return sorted({ROOT / name for name in listed if name and (ROOT / name).is_file()})


def prose_lines(text):
    """The page's lines outside fenced code, with their numbers, comments and inline code
    removed (both keep their line breaks, so the numbers stay true)."""
    text = COMMENT.sub(lambda match: "\n" * match.group(0).count("\n"), text)
    fenced = False
    for number, line in enumerate(text.split("\n"), start=1):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            yield number, line


def heading_text(source):
    """What GitHub renders for a heading's Markdown: the words of links, code and emphasis."""
    text = re.sub(r"!?\[((?:[^\[\]]|\[[^\]]*\])*)\]\([^)]*\)", r"\1", source)
    text = INLINE_CODE.sub(lambda match: match.group(2).strip(), text)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"(?<!\w)(\*{1,3}|_{1,3})(\S(?:.*?\S)?)\1(?!\w)", r"\2", text)
    return text.strip()


def slug(text):
    """GitHub's anchor for a heading's rendered text (github-slugger): lowercase; keep letters,
    marks, numbers, `_`, `-` and spaces; each space becomes `-`."""
    kept = (
        char for char in text.lower()
        if char in "-_ " or unicodedata.category(char)[0] in "LMN"
    )
    return "".join(kept).replace(" ", "-")


def anchors(path, cache={}):
    """Every anchor a page defines: its headings' slugs, repeats numbered, and explicit ids."""
    if path not in cache:
        found, seen = set(), Counter()
        text = path.read_text(encoding="utf-8")
        for _, line in prose_lines(text):
            match = HEADING.match(line)
            if match:
                base = slug(heading_text(match.group(2)))
                found.add(f"{base}-{seen[base]}" if seen[base] else base)
                seen[base] += 1
            found.update(EXPLICIT_ANCHOR.findall(line))
        cache[path] = found
    return cache[path]


def links(path):
    """The page's relative link targets, with their line numbers."""
    for number, line in prose_lines(path.read_text(encoding="utf-8")):
        line = INLINE_CODE.sub("", line)
        for target in MARKDOWN_LINK.findall(line) + HTML_LINK.findall(line):
            if not re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
                yield number, target


def broken(path):
    """Each link of the page that leads nowhere, as `file:line: target (reason)`."""
    for number, target in links(path):
        location, _, anchor = target.partition("#")
        location = unquote(location.split("?")[0])
        destination = path if not location else (
            (ROOT / location.lstrip("/")) if location.startswith("/") else path.parent / location
        ).resolve()
        where = f"{path.relative_to(ROOT)}:{number}: {target}"
        if not destination.exists():
            yield f"{where} (no such file)"
        elif anchor and destination.suffix == ".md" and unquote(anchor).lower() not in anchors(destination):
            yield f"{where} (no such heading)"


class DocLinkTests(unittest.TestCase):
    def test_slug_matches_github(self):
        cases = {
            "Switching wallpapers without a black gap": "switching-wallpapers-without-a-black-gap",
            "`scripts/check_renderer.py`": "scriptscheck_rendererpy",
            "10-bit and HDR video textures": "10-bit-and-hdr-video-textures",
            "C/C++ (CMake) test binaries": "cc-cmake-test-binaries",
            "Recovering a failed release": "recovering-a-failed-release",
            "开发与贡献": "开发与贡献",
            "What “verified” means": "what-verified-means",
        }
        for heading, expected in cases.items():
            with self.subTest(heading=heading):
                self.assertEqual(slug(heading_text(heading)), expected)

    def test_repeated_headings_are_numbered(self):
        with tempfile.TemporaryDirectory() as folder:
            page = Path(folder) / "page.md"
            page.write_text("# Limits\n\n## Limits\n\n```\n# not a heading\n```\n", encoding="utf-8")
            self.assertEqual(anchors(page), {"limits", "limits-1"})

    def test_relative_links_lead_somewhere(self):
        pages = [
            page for page in markdown_files()
            if not str(page.relative_to(ROOT)).startswith(UNCHECKED)
        ]
        self.assertTrue(pages, "found no Markdown pages to check")
        failures = [failure for page in pages for failure in broken(page)]
        if failures:
            self.fail(
                f"{len(failures)} broken link(s):\n" + "\n".join(failures[:SHOWN])
                + ("\n…" if len(failures) > SHOWN else "")
            )


if __name__ == "__main__":
    unittest.main()

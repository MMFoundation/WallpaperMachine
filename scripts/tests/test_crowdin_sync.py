#!/usr/bin/env python3
"""Unit tests for scripts/crowdin_sync.py and the format rules in scripts/lib/localization.py."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("crowdin_sync", SCRIPTS / "crowdin_sync.py")
crowdin_sync = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(crowdin_sync)

from lib.localization import translation_problem  # noqa: E402

LANGUAGES = ["ja", "zh-Hans"]

# The layout the real catalogs have: a one-line `localizations` for most keys, an expanded
# one for a few, entries that Xcode wrote with its own flags in between.
REPO = """{
  "sourceLanguage" : "en",
  "strings" : {
    "Open" : {
      "localizations" : {"ja" : {"stringUnit" : {"state" : "translated", "value" : "開く"}}, "zh-Hans" : {"stringUnit" : {"state" : "translated", "value" : "打开"}}}
    },
    "Delete %@" : {
      "extractionState" : "manual",
      "localizations" : {
        "ja" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "%@を削除"
          }
        },
        "zh-Hans" : {"stringUnit" : {"state" : "translated", "value" : "删除 %@"}},
        "en" : {"stringUnit" : {"state" : "translated", "value" : "Delete %@"}}
      }
    },
    "Quote \\"x\\"" : {
      "localizations" : {"ja" : {"stringUnit" : {"state" : "translated", "value" : "引用 \\"x\\" \\u00e9"}}, "zh-Hans" : {"stringUnit" : {"state" : "translated", "value" : "引用"}}}
    }
  },
  "version" : "1.0"
}
"""


def crowdin_catalog(strings):
    """What Crowdin hands back: every language of every key, sorted, in Xcode's expanded layout."""
    return json.dumps({
        "sourceLanguage": "en",
        "strings": {key: {"localizations": {lang: {"stringUnit": {"state": state, "value": value}}
                                            for lang, (state, value) in units.items()}}
                    for key, units in strings.items()},
        "version": "1.0",
    }, ensure_ascii=False, indent=2)


class ValueSpanTests(unittest.TestCase):
    def test_every_translation_value_is_located_and_decodes_to_itself(self):
        spans = crowdin_sync.value_spans(REPO)
        data = json.loads(REPO)
        want = {(key, lang): unit["stringUnit"]["value"]
                for key, entry in data["strings"].items() for lang, unit in entry["localizations"].items()}
        self.assertEqual(set(spans), set(want))
        for cell, (start, end) in spans.items():
            self.assertEqual(json.loads(REPO[start:end]), want[cell], cell)

    def test_a_key_that_looks_like_a_path_does_not_confuse_the_scanner(self):
        text = '{"strings": {"value": {"localizations": {"ja": {"stringUnit": {"state": "translated", "value": "x"}}}}}, "arr": [1, 2.5, null, true, {"a": []}]}'
        self.assertEqual(list(crowdin_sync.value_spans(text)), [("value", "ja")])


class MergeTests(unittest.TestCase):
    def merge(self, strings, languages=LANGUAGES):
        return crowdin_sync.merge(REPO, crowdin_catalog(strings), languages)

    def test_only_the_changed_values_are_rewritten_and_the_layout_is_kept(self):
        text, changed, refused = self.merge({
            "Open": {"ja": ("translated", "開く!"), "zh-Hans": ("translated", "打开")},
            "Delete %@": {"ja": ("translated", "%@を削除"), "zh-Hans": ("translated", "删除“%@”")},
        })
        self.assertEqual(dict(changed), {"ja": 1, "zh-Hans": 1})
        self.assertEqual(refused, [])
        self.assertEqual(text, REPO.replace('"開く"', '"開く!"').replace('"删除 %@"', '"删除“%@”"'))
        self.assertEqual(json.loads(text)["strings"]["Open"]["localizations"]["ja"]["stringUnit"]["value"], "開く!")

    def test_an_identical_catalog_changes_nothing(self):
        data = json.loads(REPO)
        theirs = {key: {lang: (unit["stringUnit"]["state"], unit["stringUnit"]["value"])
                        for lang, unit in entry["localizations"].items()} for key, entry in data["strings"].items()}
        text, changed, refused = self.merge(theirs)
        self.assertEqual((text, dict(changed), refused), (REPO, {}, []))

    def test_an_untranslated_unit_never_replaces_a_translation_with_the_english_text(self):
        text, changed, _ = self.merge({"Open": {"ja": ("new", "Open"), "zh-Hans": ("needs_review", "Open")}})
        self.assertEqual((text, dict(changed)), (REPO, {}))

    def test_a_language_the_app_does_not_ship_and_the_source_language_are_ignored(self):
        text, changed, _ = self.merge({"Open": {"de": ("translated", "Öffnen"), "en": ("translated", "Opened")}})
        self.assertEqual((text, dict(changed)), (REPO, {}))
        text, changed, _ = self.merge({"Open": {"ja": ("translated", "開く!")}}, languages=["zh-Hans"])
        self.assertEqual((text, dict(changed)), (REPO, {}))

    def test_keys_and_units_the_catalog_lacks_are_not_added(self):
        text, changed, _ = self.merge({"Brand new": {"ja": ("translated", "新しい")}, "Open": {"ko": ("translated", "열기")}})
        self.assertEqual((text, dict(changed)), (REPO, {}))

    def test_a_translation_that_would_break_the_format_is_refused_and_the_old_one_kept(self):
        text, changed, refused = self.merge({
            "Delete %@": {"ja": ("translated", "削除"), "zh-Hans": ("translated", "删除 %d")},
            "Open": {"ja": ("translated", "  ")},
        })
        self.assertEqual((text, dict(changed)), (REPO, {}))
        self.assertEqual(sorted((lang, key) for lang, key, _ in refused),
                         sorted([("ja", "Delete %@"), ("zh-Hans", "Delete %@"), ("ja", "Open")]))

    def test_values_with_quotes_and_unicode_round_trip_through_the_edit(self):
        value = 'He said "hi" \\ 日本 é'
        text, changed, _ = self.merge({'Quote "x"': {"ja": ("translated", value)}})
        self.assertEqual(dict(changed), {"ja": 1})
        self.assertEqual(json.loads(text)["strings"]['Quote "x"']["localizations"]["ja"]["stringUnit"]["value"], value)


class TranslationProblemTests(unittest.TestCase):
    def test_valid_translations_pass(self):
        self.assertIsNone(translation_problem("Delete %@", "%@を削除"))
        self.assertIsNone(translation_problem("%1$@ of %2$lld", "%2$lld 中的 %1$@"))
        self.assertIsNone(translation_problem("100%% done: %@", "已完成 100%%: %@"))
        self.assertIsNone(translation_problem("Battery 50%", "电池 50%"))

    def test_the_rules_the_catalog_test_enforces_are_enforced_before_writing(self):
        self.assertEqual(translation_problem("Open", " "), "blank")
        self.assertIn("instead of", translation_problem("Delete %@", "削除"))
        self.assertIn("instead of", translation_problem("Delete %@", "削除 %d"))
        self.assertIn("mixes", translation_problem("%@ and %@", "%1$@ 和 %@"))
        self.assertIn("unescaped", translation_problem("Done %@", "完成 100% %@"))
        self.assertIn("%%", translation_problem("Battery 50%", "电池 50%%"))


class CommandTests(unittest.TestCase):
    def run_main(self, *argv, cli="/usr/local/bin/crowdin", returncode=0):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)
            return mock.Mock(returncode=returncode, stdout="", stderr="")

        out = io.StringIO()
        with mock.patch.object(sys, "argv", ["crowdin_sync.py", *argv]), \
                mock.patch.object(crowdin_sync.shutil, "which", return_value=cli), \
                mock.patch.object(crowdin_sync.subprocess, "run", side_effect=fake_run), \
                contextlib.redirect_stdout(out):
            code = crowdin_sync.main()
        return code, calls, out.getvalue()

    def test_push_sends_sources_then_translations_without_replacing_crowdins(self):
        code, calls, _ = self.run_main("push")
        self.assertEqual(code, 0)
        self.assertEqual([call[1:3] for call in calls], [["upload", "sources"], ["upload", "translations"]])
        self.assertNotIn("--auto-approve-imported", calls[1])
        self.assertIn("--import-eq-suggestions", calls[1])
        self.assertTrue(all("-c" in call and str(crowdin_sync.CONFIG) in call for call in calls))

    def test_push_overwrite_is_the_only_way_to_replace_crowdins_translations(self):
        _, calls, _ = self.run_main("push", "--overwrite")
        self.assertIn("--auto-approve-imported", calls[1])
        self.assertNotIn("--auto-approve-imported", calls[0])

    def test_a_dry_run_push_asks_the_cli_to_send_nothing(self):
        _, calls, _ = self.run_main("push", "--dry-run")
        self.assertTrue(all("--dryrun" in call for call in calls))

    def test_push_stops_at_the_first_failing_step(self):
        code, calls, out = self.run_main("push", returncode=3)
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 1)
        self.assertIn("failed", out)

    def test_a_missing_cli_is_reported_with_how_to_install_it(self):
        code, calls, out = self.run_main("push", cli=None)
        self.assertEqual((code, calls), (1, []))
        self.assertIn("npm install -g @crowdin/cli", out)

    def test_pull_downloads_into_a_scratch_copy_and_leaves_the_repository_alone_on_a_dry_run(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            catalogs = []
            for relative in ("App/Resources/Localizable.xcstrings", "App/Resources/InfoPlist.xcstrings", "Extension/Localizable.xcstrings"):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(REPO)
                catalogs.append(path)

            def fake_download(command, **kwargs):
                base = Path(command[command.index("--base-path") + 1])
                self.assertNotEqual(base, root)
                for relative in ("App/Resources/Localizable.xcstrings", "App/Resources/InfoPlist.xcstrings", "Extension/Localizable.xcstrings"):
                    (base / relative).write_text(crowdin_catalog({"Open": {"ja": ("translated", "開く!")}}))
                return mock.Mock(returncode=0, stdout="", stderr="")

            out = io.StringIO()
            with mock.patch.object(crowdin_sync, "ROOT", root), mock.patch.object(crowdin_sync, "CATALOGS", tuple(catalogs)), \
                    mock.patch.object(crowdin_sync, "swift_languages", return_value=["en", "ja", "zh-Hans"]), \
                    mock.patch.object(crowdin_sync.shutil, "which", return_value="/usr/local/bin/crowdin"), \
                    mock.patch.object(crowdin_sync.subprocess, "run", side_effect=fake_download), \
                    contextlib.redirect_stdout(out):
                self.assertEqual(crowdin_sync.pull(dry_run=True), 0)
                self.assertTrue(all(path.read_text() == REPO for path in catalogs))
                self.assertIn("3 translation(s) would change", out.getvalue())
                self.assertEqual(crowdin_sync.pull(dry_run=False), 0)
            self.assertTrue(all(path.read_text() == REPO.replace('"開く"', '"開く!"') for path in catalogs))


if __name__ == "__main__":
    unittest.main()

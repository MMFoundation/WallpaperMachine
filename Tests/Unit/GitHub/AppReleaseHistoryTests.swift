import XCTest
@testable import WallpaperMachine

/// The bundled changelog supplies the installed release history in Settings.
final class AppReleaseHistoryTests: XCTestCase {
    func testLinkedHeadingCarriesVersionDateAndComparison() throws {
        let history = try AppReleaseHistory(markdown: entry("1.6.2"))
        let release = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(release.version.display, "1.6.2")
        XCTAssertEqual(release.date, "2026-01-01")
        XCTAssertEqual(release.url?.absoluteString, "https://github.com/o/r/compare/v1.6.1...v1.6.2")
        let legacy = try XCTUnwrap(AppReleaseHistory(markdown: """
        ## 1.0.0 — 2025-12-31
        ### English
        - Added a filter.
        ### 简体中文
        - 新增筛选。

        """).entries.first)
        XCTAssertEqual(legacy.date, "2025-12-31", "the older heading still reads")
        XCTAssertNil(legacy.url)
    }

    func testAboutSelectsPlainReleaseNotesForTheAppsLanguage() throws {
        let release = try XCTUnwrap(AppReleaseHistory(markdown: entry("1.6.2")).entries.first)
        for (tag, heading, item) in [
            ("en", "Features", "Added a library filter"),
            ("ja", "Features", "Added a library filter"),
            ("pt-BR", "Features", "Added a library filter"),
            ("zh-Hans", "新功能", "新增媒体库筛选功能"),
            ("zh-Hant", "新功能", "新增媒体库筛选功能"),
            ("ko", "새로운 기능", "보관함 필터가 추가되었습니다"),
        ] {
            let language = try XCTUnwrap(AppLanguage.named(tag))
            let section = try XCTUnwrap(release.notes(language: .init(appLanguage: language)).sections.first)
            XCTAssertEqual(section.title, heading, tag)
            XCTAssertEqual(section.items, [item], tag)
        }
    }

    func testInstalledHistoryOffersTheNewestTwentyLocalizedReleases() throws {
        let versions = (1...21).reversed().map { "2.0.\($0)" }
        let markdown = versions.map { entry($0) }.joined(separator: "\n")
        let releases = try XCTUnwrap(SoftwareUpdateController.recentReleases(markdown))
        XCTAssertEqual(releases.map(\.version.display), Array(versions.prefix(20)))
        XCTAssertEqual(releases.first?.notes(language: .korean).sections.first?.items, ["보관함 필터가 추가되었습니다"])
    }

    func testMalformedBundledHistoryIsUnavailableAndAnEmptyChangelogHasNoEntries() {
        XCTAssertNil(SoftwareUpdateController.recentReleases(entry("1.5.7", korean: false)))
        XCTAssertNil(SoftwareUpdateController.recentReleases("## Unreleased\n"))
        XCTAssertEqual(SoftwareUpdateController.recentReleases("# Changelog\n"), [])
    }

    func testHistoryRejectsMissingTranslationsAndDuplicateVersions() throws {
        XCTAssertThrowsError(try AppReleaseHistory(markdown: "## 1.0.0 — 2026-01-01\n### English\n- Added a filter."))
        XCTAssertThrowsError(try AppReleaseHistory(markdown: entry("1.0.0") + entry("1.0.0")))
        XCTAssertThrowsError(try AppReleaseHistory(markdown: entry("invalid")))
        let history = try AppReleaseHistory(markdown: entry("1.0.0"))
        XCTAssertEqual(history.entries.first?.chinese.sections.first?.items, ["新增媒体库筛选功能"], "Reference links are not release prose")
    }

    func testMixedHistoryKeepsKoreanSeparateAndFallsBackOnlyForLegacyEntries() throws {
        let history = try AppReleaseHistory(markdown: entry("1.5.7") + entry("1.5.6"))
        let current = try XCTUnwrap(history.entries.first)
        let legacy = try XCTUnwrap(history.entries.last)
        XCTAssertEqual(current.notes(language: .english).sections.first?.items, ["Added a library filter"])
        XCTAssertEqual(current.notes(language: .chinese).sections.first?.items, ["新增媒体库筛选功能"])
        XCTAssertEqual(current.korean?.sections.first?.items, ["보관함 필터가 추가되었습니다"])
        XCTAssertEqual(current.notes(language: .korean), try XCTUnwrap(current.korean))
        XCTAssertNil(legacy.korean, "A later Korean block must not leak into another release")
        XCTAssertEqual(legacy.notes(language: .korean), legacy.english)
        XCTAssertEqual(legacy.chinese.sections.count, 1)
        XCTAssertEqual(legacy.chinese.sections.first?.items, ["新增媒体库筛选功能"])
    }

    func testKoreanIsRequiredStartingWithVersionOneFiveSeven() throws {
        XCTAssertNoThrow(try AppReleaseHistory(markdown: entry("1.5.6", korean: false)))
        for version in ["1.5.7", "1.5.8", "1.6.0", "2.0.0"] {
            XCTAssertThrowsError(try AppReleaseHistory(markdown: entry(version, korean: false)), version) { error in
                XCTAssertEqual(error as? AppReleaseHistory.InvalidHistory, .missingTranslation)
            }
            XCTAssertNoThrow(try AppReleaseHistory(markdown: entry(version, korean: true)), version)
        }
        XCTAssertNoThrow(try AppReleaseHistory(markdown: entry("1.5.6", korean: true)),
                         "An older section may have Korean without making it mandatory for all older versions")
    }

    func testExplicitKoreanBlockCannotBeEmptyOrOnlyHeadingsAndBanner() throws {
        for version in ["1.5.6", "1.5.7"] {
            for replacement in ["", "![한국어](Resources/ReleaseBanners/\(version).ko.jpg)"] {
                let markdown = entry(version, korean: true).replacingOccurrences(
                    of: "- 보관함 필터가 추가되었습니다 (closes [#76](https://github.com/o/r/issues/76), closes [#77](https://github.com/o/r/issues/77)) ([abc1234](https://github.com/o/r/commit/abc1234def))", with: replacement)
                XCTAssertThrowsError(try AppReleaseHistory(markdown: markdown)) { error in
                    XCTAssertEqual(error as? AppReleaseHistory.InvalidHistory, .missingTranslation)
                }
            }
        }
    }

    func testLanguageHeadingsMustBeKnownUniqueAndOrdered() throws {
        let valid = entry("1.5.7")
        let cases = [
            valid.replacingOccurrences(of: "### 한국어", with: "### Japanese"),
            valid.replacingOccurrences(of: "### 简体中文", with: "### English"),
            valid.replacingOccurrences(of: "### 한국어", with: "### 简体中文"),
            valid.replacingOccurrences(of: "### English", with: "### 简体中文"),
            valid.replacingOccurrences(of: "### 简体中文", with: "### 한국어"),
            valid.replacingOccurrences(of: "### 한국어", with: "### 한국어\n### 한국어"),
            valid.replacingOccurrences(of: "### English", with: "###English"),
            valid + "### Other changes\n- Unexpected category level\n",
        ]
        for markdown in cases {
            XCTAssertThrowsError(try AppReleaseHistory(markdown: markdown)) { error in
                XCTAssertEqual(error as? AppReleaseHistory.InvalidHistory, .invalidLanguageHeading)
            }
        }
        let spaced = valid.replacingOccurrences(of: "### 한국어", with: "###\t한국어  ")
        XCTAssertNoThrow(try AppReleaseHistory(markdown: spaced))
    }

    func testHistoryRejectsUnreleasedAndHeadingsInsideNotes() throws {
        XCTAssertThrowsError(try AppReleaseHistory(markdown: """
        ## Unreleased
        ### English
        - Soon.
        ### 简体中文
        - 即将发布。

        """)) { error in
            XCTAssertEqual(error as? AppReleaseHistory.InvalidHistory, .invalidVersion)
        }
        XCTAssertThrowsError(try AppReleaseHistory(markdown: entry("1.0.0").replacingOccurrences(
            of: "#### Features\n",
            with: "#### Features\n## Also see\n"
        )))
    }

    func testSemanticVersionRejectsInvalidAndOrdersStableReleases() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("1.2"))
        XCTAssertNil(SemanticVersion("v1.2.3-beta"))
        XCTAssertNil(SemanticVersion("01.2.3"))
        XCTAssertEqual(SemanticVersion("v1.2.3")?.display, "1.2.3")
        XCTAssertLessThan(SemanticVersion("0.1.0")!, SemanticVersion("0.1.1")!)
        XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("1.0.0")!)
        XCTAssertEqual(SemanticVersion("V2.0.0"), SemanticVersion("2.0.0"))
    }

    func testReleaseNotesReadTheSectionsAndStopAtTheInstallFooter() throws {
        let body = """
        ![WallpaperMachine 1.2.3](https://raw.githubusercontent.com/o/r/v1.2.3/Resources/ReleaseBanners/1.2.3.jpg)

        ### New

        - **panel** — Add a filter rail ([`aaa1111`](https://github.com/o/r/commit/aaa1111))

        ### Fixed

        - **scene** — Stop a crash ([`bbb2222`](https://github.com/o/r/commit/bbb2222))

        Plus 3 documentation, test and tooling commits.

        **Full changelog**: https://github.com/o/r/compare/v1.2.2...v1.2.3

        \(ReleaseNotes.boundary)

        ### Install

        1. Open `WallpaperMachine-1.2.3-arm64.dmg` and drag WallpaperMachine to Applications.
        """
        let notes = try XCTUnwrap(ReleaseNotes(version: "1.2.3", body: body))
        XCTAssertEqual(notes.sections.map(\.title), ["New", "Fixed", ""])
        XCTAssertEqual(notes.sections[0].items, ["panel — Add a filter rail"])
        XCTAssertEqual(notes.sections[1].items, ["scene — Stop a crash"])
        XCTAssertEqual(notes.sections[2].items, ["Plus 3 documentation, test and tooling commits."])
    }

    func testReleaseNotesRecognizeTranslatedHighlightsWithoutHighlightingOtherSections() throws {
        for (highlights, fixed) in [("Highlights", "Fixed"), ("亮点", "修复"), ("주요 변경 사항", "수정됨")] {
            let notes = try XCTUnwrap(ReleaseNotes(version: "1.5.7", body: """
            #### \(highlights)
            - A highlighted change
            #### \(fixed)
            - An ordinary fix
            """))
            XCTAssertEqual(notes.sections.count, 2)
            XCTAssertEqual(notes.sections.map(\.isHighlights), [true, false])
            XCTAssertTrue(notes.sections.allSatisfy(\.isList))
        }
    }

    func testReleaseNotesDropIssueAndCommitReferencesFromThePlainReading() throws {
        let notes = try XCTUnwrap(ReleaseNotes(version: "1.6.2", body: """
        #### Bug Fixes

        - Names fit on narrow tiles (closes [#76](https://github.com/o/r/issues/76), closes [#77](https://github.com/o/r/issues/77)) ([bb75725](https://github.com/o/r/commit/bb75725aa))
        - Stop a crash ([aaa1111](https://github.com/o/r/commit/aaa1111), [bbb2222](https://github.com/o/r/commit/bbb2222))
        - Read the [guide](https://github.com/o/r/wiki) (see [notes](https://github.com/o/r/wiki/notes))
        """))
        XCTAssertEqual(notes.sections.first?.items, [
            "Names fit on narrow tiles", "Stop a crash", "Read the guide (see notes)",
        ])
    }

    func testAReleaseWithNothingToSayHasNoNotes() {
        XCTAssertNil(ReleaseNotes(version: "1.2.3", body: ""))
        XCTAssertNil(ReleaseNotes(version: "1.2.3",
                                  body: "**Full changelog**: https://github.com/o/r/compare/v1.2.2...v1.2.3"))
    }

    private func entry(_ version: String, korean: Bool? = nil) -> String {
        let includesKorean = korean ?? (SemanticVersion(version).map {
            ($0.major, $0.minor, $0.patch) >= (1, 5, 7)
        } ?? false)
        let links = "(closes [#76](https://github.com/o/r/issues/76), closes [#77](https://github.com/o/r/issues/77)) ([abc1234](https://github.com/o/r/commit/abc1234def))"
        let koreanNotes = includesKorean ? "### 한국어\n#### 새로운 기능\n- 보관함 필터가 추가되었습니다 \(links)\n" : ""
        let previous = SemanticVersion(version).map { "\($0.major).\($0.minor).\(max($0.patch, 1) - 1)" } ?? "0.0.0"
        return """
        ## [\(version)](https://github.com/o/r/compare/v\(previous)...v\(version)) (2026-01-01)
        ### English
        #### Features
        - Added a library filter \(links)
        ### 简体中文
        #### 新功能
        - 新增媒体库筛选功能 \(links)
        \(koreanNotes)
        """
    }
}

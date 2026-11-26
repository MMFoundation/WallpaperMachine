import Foundation
import XCTest

@testable import WallpaperMachine

/// Unit tests for Pixiv Deep Browsing Phase B:
/// 1. Direct URL / bare illust ID lookup (`PixivService.detail(id:)`, `PixivStore`)
/// 2. In-app Author page + bounded `Back` navigation stack (`PixivService`, `PixivStore`, `PixivBrowserModel`)
/// 3. Signed-in Bookmarks & Following feeds + signed-out gating (`PixivService`, `PixivStore`, `PixivBrowseState`)
/// 4. Dedicated Japanese-tag search translation (`PixivSearchTranslator`, `PixivBrowserModel`, `PanelController+Pixiv`)
@MainActor
final class PixivDeepBrowsingTests: MediaPanelTestCase {
    private typealias Work = PixivFixtures.Work

    private func makeStore(
        _ transport: any PixivTransport,
        sessions: PixivMemorySessionStore = PixivMemorySessionStore()
    ) -> PixivStore {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pixiv-phase-b-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: library) }
        let service = PixivService(transport: transport, minimumInterval: .zero)
        return PixivStore(
            service: service,
            packager: PixivWallpaperPackager(library: library) { data, _ in data },
            sessions: sessions)
    }

    private func waitUntil(
        timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        try await waitFor(timeout: timeout, file: file, line: line, condition)
    }

    // MARK: - 1. Direct URL / Illust ID Lookup

    func testServiceDetailDecodesArtworkMetadataAndRejectsInvalidInputs() async throws {
        let transport = PixivFixtureTransport { url in
            if url.path == "/ajax/illust/12345678" {
                return PixivFixtures.detail(
                    Work(id: 12345678, width: 2560, height: 1440, pages: 3, aiType: 2, title: "Starlight", tags: ["星空", "風景"]),
                    authorID: "998877", authorName: "Kaze")
            }
            if url.path == "/ajax/illust/87654321" {
                return PixivFixtures.detail(Work(id: 87654321, type: 2))
            }
            throw PixivFailure(code: .status(404))
        }
        let service = PixivService(transport: transport, minimumInterval: .zero)

        let work = try await service.detail(id: "12345678")
        XCTAssertEqual(work.id, "12345678")
        XCTAssertEqual(work.title, "Starlight")
        XCTAssertEqual(work.authorID, "998877")
        XCTAssertEqual(work.authorName, "Kaze")
        XCTAssertEqual(work.width, 2560)
        XCTAssertEqual(work.height, 1440)
        XCTAssertEqual(work.pageCount, 3)
        XCTAssertEqual(work.aiGenerated, true)
        XCTAssertEqual(work.tags, ["星空", "風景"])
        XCTAssertEqual(work.thumbnailURL?.host, "i.pximg.net")

        await XCTAssertPixivFailure(try await service.detail(id: "87654321"), .notAnImage)
        await XCTAssertPixivFailure(try await service.detail(id: "99999999"), .status(404))
        await XCTAssertPixivFailure(try await service.detail(id: "../etc"), .unreadable)
        XCTAssertEqual(
            transport.requests.map(\.path),
            ["/ajax/illust/12345678", "/ajax/illust/87654321", "/ajax/illust/99999999"],
            "malformed ids never touch transport")
    }

    func testStoreDirectURLAndBareIDJumpFetchesDetailAndSelectsInInspector() async throws {
        let transport = PixivFixtureTransport { url in
            if url.path == "/ajax/illust/12345678" {
                return PixivFixtures.detail(
                    Work(id: 12345678, width: 1080, height: 1920, pages: 2, sanity: 4, title: "Direct Hit"),
                    authorID: "4200", authorName: "DirectArtist")
            }
            if url.path == "/ajax/illust/12345678/pages" {
                return PixivFixtures.pages(workID: 12345678, count: 2)
            }
            if url.path == "/ajax/illust/44444444" {
                throw PixivFailure(code: .status(404))
            }
            if url.path == "/ajax/illust/55555555" {
                return PixivFixtures.detail(Work(id: 55555555, xRestrict: 2))
            }
            return PixivFixtures.ranking([])
        }
        let store = makeStore(transport)

        // Direct URL lookup ignores landscape orientation filter and auto-selects the work.
        var query = PixivQuery(text: "https://www.pixiv.net/en/artworks/12345678", orientation: .landscape)
        store.apply(query)
        try await waitUntil { store.hasLoaded && !store.isLoading && store.selectedPageList != nil }

        XCTAssertEqual(store.works.map(\.id), ["12345678"])
        XCTAssertEqual(store.selectedWork?.id, "12345678", "direct jump selects the work immediately")
        XCTAssertEqual(store.selectedPageList?.count, 2)
        XCTAssertFalse(transport.requests.contains { $0.path.hasPrefix("/ajax/search/") })

        // Bare ID not found surfaces clean 404 error without crashing or leaving old results.
        query.text = "44444444"
        store.apply(query)
        try await waitUntil { store.errorMessage != nil && !store.isLoading }
        XCTAssertTrue(store.works.isEmpty)
        XCTAssertEqual(store.errorMessage, PixivFailure(code: .status(404)).localizedDescription)

        // R-18G is never shown even on a direct URL jump.
        query.text = "pixiv.net/i/55555555"
        store.apply(query)
        try await waitUntil { store.hasLoaded && !store.isLoading }
        XCTAssertTrue(store.works.isEmpty)
        XCTAssertEqual(store.hiddenCount, 1)
    }

    // MARK: - 2. Author Profile Pagination & Bounded Back Navigation Stack

    func testServiceAuthorWorksValidatesAuthorIDAndPaginatesSlicesInNewestFirstOrder() async throws {
        // 50 works -> page 1 fetches 48 ids, page 2 fetches remaining 2 ids, in descending numeric id order.
        let ids = Array(1001...1050)
        let transport = PixivFixtureTransport { url in
            if url.path == "/ajax/user/7777/profile/all" {
                return PixivFixtures.authorProfileAll(illustIDs: ids)
            }
            if url.path == "/ajax/user/7777/profile/illusts" {
                let requested = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                    .filter { $0.name == "ids[]" }
                    .compactMap { $0.value.flatMap(Int.init) }
                return PixivFixtures.authorIllusts(
                    requested.map { Work(id: $0) }, authorID: "7777", authorName: "Mika")
            }
            if url.path == "/ajax/user/8888/profile/all" {
                return PixivFixtures.authorProfileAll(illustIDs: [])
            }
            throw PixivFailure(code: .status(404))
        }
        let service = PixivService(transport: transport, minimumInterval: .zero)

        let page1 = try await service.page(1, of: .author(id: "7777"))
        XCTAssertEqual(page1.works.count, PixivService.authorPageSize)
        XCTAssertEqual(page1.works.first?.id, "1050", "newest work first")
        XCTAssertEqual(page1.works.last?.id, "1003")
        XCTAssertEqual(page1.totalCount, 50)
        XCTAssertEqual(page1.totalPages, 2)

        let page2 = try await service.page(2, of: .author(id: "7777"))
        XCTAssertEqual(page2.works.map(\.id), ["1002", "1001"])
        XCTAssertEqual(
            transport.requests.filter { $0.path.hasSuffix("/profile/all") }.count, 1,
            "profile/all is cached across pages of the same author")

        let emptyAuthor = try await service.page(1, of: .author(id: "8888"))
        XCTAssertTrue(emptyAuthor.works.isEmpty)
        XCTAssertEqual(emptyAuthor.totalCount, 0)

        await XCTAssertPixivFailure(try await service.page(1, of: .author(id: "not-numeric")), .unreadable)
        await XCTAssertPixivFailure(try await service.page(1, of: .author(id: "7777/../1")), .unreadable)
        XCTAssertNil(PixivService.authorProfileAllURL(authorID: "0"))
        XCTAssertNil(PixivService.authorIllustsURL(authorID: "7777", ids: []))
    }

    func testStoreBackStackPreservesModeQueryFiltersPageSelectionAndIsBounded() async throws {
        let transport = PixivFixtureTransport { url in
            if url.path.hasPrefix("/ajax/search/") {
                let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "p" }?.value.flatMap(Int.init) ?? 1
                let entries = (1...60).map {
                    var entry = PixivFixtures.searchEntry(Work(id: (page - 1) * 60 + $0))
                    entry["userId"] = "5001"
                    entry["userName"] = "Alpha"
                    return entry
                }
                return PixivFixtures.search(entries, total: 120, lastPage: 2)
            }
            if url.path.hasSuffix("/profile/all") {
                let authorID = url.pathComponents[3]
                let base = (Int(authorID) ?? 1) * 100
                return PixivFixtures.authorProfileAll(illustIDs: [base + 1, base + 2])
            }
            if url.path.hasSuffix("/profile/illusts") {
                let authorID = url.pathComponents[3]
                let base = (Int(authorID) ?? 1) * 100
                return PixivFixtures.authorIllusts(
                    [Work(id: base + 2), Work(id: base + 1)], authorID: authorID, authorName: "Author \(authorID)")
            }
            if url.path.hasSuffix("/pages") {
                let id = Int(url.pathComponents.dropLast().last ?? "") ?? 0
                return PixivFixtures.pages(workID: id, count: 3)
            }
            return PixivFixtures.ranking([])
        }
        let store = makeStore(transport)

        // Start on a search query, page 2, with filters + a selected work on page index 1.
        let searchQuery = PixivQuery(
            text: "風景", order: .oldest, orientation: .landscape, hidesAIGenerated: true)
        store.apply(searchQuery)
        try await waitUntil { store.hasLoaded && !store.isLoading }
        store.loadPage(2)
        try await waitUntil { store.page == 2 && !store.isLoading }
        let selectedBefore = try XCTUnwrap(store.works.first)
        store.select(selectedBefore)
        try await waitUntil { store.selectedPageList?.count == 3 }
        store.selectPage(1)

        // Navigate into Author 5001, then into Author 5002.
        let requestsBeforeAuthor = transport.requests.count
        store.openAuthor(id: "5001", name: "Alpha", leavingAt: 240)
        try await waitUntil { store.query.scope == .author(id: "5001", name: "Alpha") && store.hasLoaded && !store.isLoading }
        XCTAssertTrue(store.canGoBack)
        XCTAssertEqual(store.backStackCount, 1)
        XCTAssertNil(store.selectedWork)
        XCTAssertEqual(store.works.map(\.id), ["500102", "500101"])

        store.openAuthor(id: "5002", name: "Beta", leavingAt: 80)
        try await waitUntil { store.query.scope == .author(id: "5002", name: "Beta") && store.hasLoaded && !store.isLoading }
        XCTAssertEqual(store.backStackCount, 2)

        // Pop back to Author 5001.
        let offset1 = store.goBack()
        XCTAssertEqual(offset1, 80)
        XCTAssertEqual(store.query.scope, .author(id: "5001", name: "Alpha"))
        XCTAssertEqual(store.backStackCount, 1)

        // Pop back to Search page 2 with filters, selection, page index, and cached results intact!
        let requestsBeforeFinalPop = transport.requests.count
        let offset2 = store.goBack()
        XCTAssertEqual(offset2, 240)
        XCTAssertFalse(store.canGoBack)
        XCTAssertEqual(store.query, searchQuery)
        XCTAssertEqual(store.page, 2)
        XCTAssertEqual(store.selectedWork?.id, selectedBefore.id)
        XCTAssertEqual(store.selectedPage, 1)
        XCTAssertEqual(
            transport.requests.count, requestsBeforeFinalPop,
            "returning to a cached browse snapshot under the same session reuses cached pages")
        XCTAssertGreaterThan(requestsBeforeFinalPop, requestsBeforeAuthor)

        // Verify stack bound (`maxHistory`).
        for i in 1...(PixivStore.maxHistory + 5) {
            store.openAuthor(id: String(6000 + i), name: "Artist \(i)")
        }
        XCTAssertEqual(store.backStackCount, PixivStore.maxHistory)

        // Switching to a top-level scope clears the Back stack.
        store.openScope(.explore)
        XCTAssertFalse(store.canGoBack)
    }

    // MARK: - 3. Signed-In Bookmarks & Following Feeds + Signed-Out Gating

    func testServiceBookmarksAndFollowingRequireValidSessionAndDecodePagination() async throws {
        let transport = PixivFixtureTransport(respondingToSession: { url, session in
            guard session == PixivFixtures.session else { throw PixivFailure(code: .status(403)) }
            if url.path == "/ajax/user/31415926/illusts/bookmarks" {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let rest = items.first { $0.name == "rest" }?.value ?? "show"
                let offset = items.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
                let base = rest == "hide" ? 9000 : 8000
                return PixivFixtures.bookmarks(
                    [PixivFixtures.searchEntry(Work(id: base + offset + 1))], total: 96)
            }
            if url.path == "/ajax/follow_latest/illust" {
                let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "p" }?.value.flatMap(Int.init) ?? 1
                let entries = [
                    PixivFixtures.searchEntry(Work(id: page * 100 + 2)),
                    PixivFixtures.searchEntry(Work(id: page * 100 + 1)),
                ]
                return PixivFixtures.following(
                    entries, ids: [page * 100 + 1, page * 100 + 2], isLastPage: page >= 2)
            }
            throw PixivFailure(code: .status(404))
        })
        let service = PixivService(transport: transport, minimumInterval: .zero)

        // Signed-out requests throw immediately and NEVER hit transport.
        await XCTAssertPixivFailure(
            try await service.page(1, of: .bookmarks(visibility: .public), session: nil), .signedOut)
        await XCTAssertPixivFailure(
            try await service.page(1, of: .following, session: nil), .signedOut)
        XCTAssertTrue(transport.requests.isEmpty, "no unauthenticated calls may be sent")

        // Bookmarks public vs private + offset pagination.
        let pub = try await service.page(2, of: .bookmarks(visibility: .public), session: PixivFixtures.session)
        XCTAssertEqual(pub.works.map(\.id), ["8049"])
        XCTAssertEqual(pub.totalPages, 2)
        let priv = try await service.page(1, of: .bookmarks(visibility: .private), session: PixivFixtures.session)
        XCTAssertEqual(priv.works.map(\.id), ["9001"])

        // Following preserves `page.ids` order and pagination.
        let follow1 = try await service.page(1, of: .following, session: PixivFixtures.session)
        XCTAssertEqual(follow1.works.map(\.id), ["101", "102"], "ordered by page.ids")
        XCTAssertEqual(follow1.totalPages, 2)
        let follow2 = try await service.page(2, of: .following, session: PixivFixtures.session)
        XCTAssertEqual(follow2.works.map(\.id), ["201", "202"])
        XCTAssertEqual(follow2.totalPages, 2)

        // HTTP 403 maps to `.signedOut`.
        await XCTAssertPixivFailure(
            try await service.page(1, of: .following, session: PixivFixtures.otherSession), .signedOut)
    }

    func testStoreBookmarksAndFollowingGateWhenSignedOutAndLoadOnSignIn() async throws {
        let transport = PixivFixtureTransport(respondingToSession: { url, session in
            let known = session == PixivFixtures.session
            if url.path == "/touch/ajax/user/self/status" {
                return PixivFixtures.status(signedIn: known, id: "31415926", name: "Tester")
            }
            if url.path == "/ajax/user/31415926/illusts/bookmarks" {
                guard known else { throw PixivFailure(code: .status(403)) }
                return PixivFixtures.bookmarks([PixivFixtures.searchEntry(Work(id: 8101))], total: 1)
            }
            if url.path == "/ajax/follow_latest/illust" {
                guard known else { throw PixivFailure(code: .status(403)) }
                return PixivFixtures.following([PixivFixtures.searchEntry(Work(id: 9101))], isLastPage: true)
            }
            return PixivFixtures.ranking([])
        })
        let store = makeStore(transport)

        // Switch to Bookmarks while signed out: zero network calls, empty state asks to sign in.
        store.openScope(.bookmarks(.public))
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(PixivEmptyState.make(PixivBrowseState(store)), .signInRequired(.bookmarks))

        // Switch to Following while signed out: still zero network calls.
        store.openScope(.following)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(PixivEmptyState.make(PixivBrowseState(store)), .signInRequired(.following))
        XCTAssertNil(store.signedInUserID)

        // Sign in: Following loads automatically with the session and signedInUserID is extracted.
        store.signIn { PixivFixtures.session }
        try await waitUntil { store.hasLoaded && !store.isLoading && store.account != nil }
        XCTAssertEqual(store.signedInUserID, "31415926")
        XCTAssertEqual(store.works.map(\.id), ["9101"])
        XCTAssertEqual(transport.sessions.last, PixivFixtures.session)

        // Switch to Bookmarks while signed in: loads immediately using extracted userID.
        store.openScope(.bookmarks(.public))
        try await waitUntil { store.committedQuery?.scope == .bookmarks(.public) && store.hasLoaded && !store.isLoading }
        XCTAssertEqual(store.works.map(\.id), ["8101"])

        // Sign out: immediately clears results and makes zero unauthenticated calls.
        let countBeforeSignOut = transport.requests.count
        try store.signOut()
        XCTAssertTrue(store.works.isEmpty)
        XCTAssertEqual(PixivEmptyState.make(PixivBrowseState(store)), .signInRequired(.bookmarks))
        XCTAssertEqual(transport.requests.count, countBeforeSignOut)
    }

    // MARK: - 4. Dedicated Japanese-Tag Search Translation (`PixivSearchTranslator`)

    func testPixivSearchTranslatorTargetsJapaneseAndSkipsJapaneseURLsAndIDs() async throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        var recorded: [(text: String, source: String, target: String)] = []
        let table = [
            "sunset sky": "夕焼け空。",
            "赛博朋克城市": "サイバーパンク都市",
            "고양이": "猫",
            "gato preto": "黒猫",
        ]
        var appLang = AppLanguage.english
        let translator = PixivSearchTranslator(
            defaults: defaults,
            translate: { text, source, target in
                recorded.append((text, source.minimalIdentifier, target.minimalIdentifier))
                return table[text] ?? text
            },
            appLanguage: { appLang })

        XCTAssertTrue(translator.isEnabled, "enabled by default when app language != Japanese")

        // Translates English -> Japanese (`ja`), stripping trailing Japanese full stop.
        let en = await translator.translation(for: "  sunset sky  ")
        XCTAssertEqual(en, PixivSearchTranslation(original: "sunset sky", japanese: "夕焼け空", language: "en"))

        // Translates Simplified Chinese -> Japanese (`ja`).
        let zh = await translator.translation(for: "赛博朋克城市")
        XCTAssertEqual(zh?.japanese, "サイバーパンク都市")
        XCTAssertEqual(zh?.language, "zh-Hans")

        // Translates Korean -> Japanese (`ja`).
        let ko = await translator.translation(for: "고양이")
        XCTAssertEqual(ko?.japanese, "猫")
        XCTAssertEqual(ko?.language, "ko")

        // Translates Portuguese when app is in Portuguese.
        appLang = AppLanguage.named("pt-BR")!
        let pt = await translator.translation(for: "gato preto")
        XCTAssertEqual(pt?.japanese, "黒猫")
        XCTAssertEqual(pt?.language, "pt-BR")
        appLang = .english

        // Every single call targeted Japanese (`ja`), never English (`en`)!
        XCTAssertTrue(recorded.allSatisfy { $0.target == "ja" }, "must always target Japanese: \(recorded)")
        let countAfterValid = recorded.count

        // Skips empty, Japanese Kana (Hiragana/Katakana), pure Japanese kanji, pixiv URLs, bare IDs.
        let skipped = [
            "",
            "   ",
            "さくら",
            "サイバーパンク",
            "桜の木",
            "初音ミク",
            "東京",
            "https://www.pixiv.net/artworks/12345678",
            "https://www.pixiv.net/en/artworks/12345678",
            "pixiv.net/i/12345678",
            "12345678",
            "https://example.com/sunset",
            "123",
        ]
        for query in skipped {
            let result = await translator.translation(for: query)
            XCTAssertNil(result, "should skip translation for: \(query)")
        }
        XCTAssertEqual(recorded.count, countAfterValid, "skipped inputs must never call the translator")

        // Repeated query hits cache without re-invoking closure.
        let cached = await translator.translation(for: "sunset sky")
        XCTAssertEqual(cached?.japanese, "夕焼け空")
        XCTAssertEqual(recorded.count, countAfterValid)
    }

    func testPixivSearchTranslatorDefaultsAndPersistsEnabledKey() async throws {
        let defaults = try TemporaryDefaults.make(for: self).defaults

        // Default is `false` when app language is Japanese, `true` otherwise.
        let jaDefault = PixivSearchTranslator(
            defaults: defaults,
            translate: { text, _, _ in text },
            appLanguage: { AppLanguage.named("ja")! })
        XCTAssertFalse(jaDefault.isEnabled)

        let enDefault = PixivSearchTranslator(
            defaults: defaults,
            translate: { text, _, _ in text },
            appLanguage: { .english })
        XCTAssertTrue(enDefault.isEnabled)

        // Persists explicit toggle under `PixivSearchTranslator.enabledKey`.
        enDefault.setEnabled(false)
        XCTAssertEqual(defaults.object(forKey: PixivSearchTranslator.enabledKey) as? Bool, false)
        let disabledResult = await enDefault.translation(for: "sunset sky")
        XCTAssertNil(disabledResult, "disabled translator never translates")

        let reloaded = PixivSearchTranslator(
            defaults: defaults,
            translate: { _, _, _ in "空" },
            appLanguage: { .english })
        XCTAssertFalse(reloaded.isEnabled)

        reloaded.resetPreference()
        XCTAssertNil(defaults.object(forKey: PixivSearchTranslator.enabledKey))
        XCTAssertTrue(reloaded.isEnabled)
    }

    // MARK: - 5. PixivBrowserModel End-to-End State Transitions

    func testBrowserModelHandlesPastedURLAuthorBackAndSearchAsTyped() async throws {
        let image = try PanelTestCase.gif(frames: 1, brightness: 0.6)
        let transport = PixivFixtureTransport(respondingToSession: { url, session in
            if url.host == "i.pximg.net" { return image }
            if url.path == "/touch/ajax/user/self/status" {
                return PixivFixtures.status(signedIn: session == PixivFixtures.session)
            }
            if url.path == "/ajax/illust/99887766" {
                return PixivFixtures.detail(
                    Work(id: 99887766, title: "Pasted Artwork"), authorID: "3344", authorName: "Sora")
            }
            if url.path.hasSuffix("/pages") {
                return PixivFixtures.pages(workID: 99887766, count: 1)
            }
            if url.path == "/ajax/user/3344/profile/all" {
                return PixivFixtures.authorProfileAll(illustIDs: [99887766, 99887700])
            }
            if url.path == "/ajax/user/3344/profile/illusts" {
                return PixivFixtures.authorIllusts(
                    [Work(id: 99887766), Work(id: 99887700)], authorID: "3344", authorName: "Sora")
            }
            if url.path.hasPrefix("/ajax/search/") {
                return PixivFixtures.search([PixivFixtures.searchEntry(Work(id: 7101))], total: 1, lastPage: 1)
            }
            return PixivFixtures.ranking([PixivFixtures.rankingEntry(Work(id: 301), rank: 1)], total: 1)
        })

        try await withPanel(pixivTransport: transport) { panel in
            let controller = panel.controller
            let pixiv = panel.pixiv
            let defaults = panel.defaults
            let model = controller.pixivBrowser
            model.searchTranslator = PixivSearchTranslator(
                defaults: defaults,
                translate: { text, _, target in
                    XCTAssertEqual(target, PixivSearchTranslator.japanese)
                    return text == "sunset" ? "夕焼け" : text
                },
                appLanguage: { .english })

            // 1. Search English tag -> translates to Japanese and displays translation banner state.
            model.setText("sunset")
            await model.submit().value
            try await waitUntil { pixiv.hasLoaded && !pixiv.isLoading }
            XCTAssertEqual(controller.pixivBrowse.translation?.japanese, "夕焼け")
            XCTAssertEqual(controller.pixivBrowse.translation?.original, "sunset")
            XCTAssertTrue(transport.requests.contains { $0.path == "/ajax/search/illustrations/夕焼け" })

            // 2. Click "Search as typed" -> searches original English tag without translation.
            let activeTranslation = try XCTUnwrap(controller.pixivBrowse.translation)
            await model.searchAsTyped(activeTranslation).value
            try await waitUntil { pixiv.committedQuery?.translation == nil && !pixiv.isLoading }
            XCTAssertNil(controller.pixivBrowse.translation)
            XCTAssertEqual(transport.requests.last?.path, "/ajax/search/illustrations/sunset")

            // 3. Paste a Pixiv URL -> jumps immediately to detail and selects the artwork.
            model.setText("https://www.pixiv.net/artworks/99887766")
            try await waitUntil { pixiv.selectedWork?.id == "99887766" && pixiv.hasLoaded && !pixiv.isLoading }
            XCTAssertTrue(controller.pixivBrowse.isDirectLookup)
            XCTAssertEqual(controller.pixivBrowse.works.map(\.id), ["99887766"])

            // 4. Open author from selected work -> pushes Back stack; Go back restores URL jump & selection.
            let jumped = try XCTUnwrap(pixiv.selectedWork)
            model.scrolled(to: 120)
            await model.openAuthor(of: jumped)?.value
            try await waitUntil {
                controller.pixivBrowse.scope == .author(id: "3344", name: "Sora") && !pixiv.isLoading
            }
            XCTAssertTrue(controller.pixivBrowse.canGoBack)
            XCTAssertEqual(controller.pixivBrowse.works.map(\.id), ["99887766", "99887700"])

            await model.goBack().value
            try await waitUntil { controller.pixivBrowse.scope == .explore && !pixiv.isLoading }
            XCTAssertFalse(controller.pixivBrowse.canGoBack)
            XCTAssertEqual(model.draft.text, "https://www.pixiv.net/artworks/99887766")
            XCTAssertEqual(pixiv.selectedWork?.id, "99887766")
            XCTAssertEqual(model.takePendingBackScrollOffset(), 120)

            // 5. Toggle translation off persists to UserDefaults and turns bar into off-state on translatable searches.
            await model.setTranslatesSearches(false).value
            XCTAssertFalse(model.translatesSearches)
            XCTAssertEqual(defaults.object(forKey: PixivSearchTranslator.enabledKey) as? Bool, false)

            // 6. Switching to Bookmarks while signed out triggers sign-in required empty state with zero requests.
            let requestsBeforeBookmarks = transport.requests.count
            await model.open(tab: .bookmarks).value
            XCTAssertEqual(controller.pixivBrowse.scope, .bookmarks(.public))
            XCTAssertEqual(PixivEmptyState.make(controller.pixivBrowse), .signInRequired(.bookmarks))
            XCTAssertEqual(transport.requests.count, requestsBeforeBookmarks)
        }
    }

    // MARK: - 6. Concurrency, Cache Ordering & Mid-Load State Regressions

    func testRapidSearchAndNavigationCancelStaleTranslationWithoutClobbering() async throws {
        let image = try PanelTestCase.gif(frames: 1, brightness: 0.6)
        let transport = PixivFixtureTransport(respondingToSession: { url, session in
            if url.host == "i.pximg.net" { return image }
            if url.path == "/touch/ajax/user/self/status" {
                return PixivFixtures.status(signedIn: session == PixivFixtures.session)
            }
            if url.path == "/ajax/user/3344/profile/all" {
                return PixivFixtures.authorProfileAll(illustIDs: [8801])
            }
            if url.path == "/ajax/user/3344/profile/illusts" {
                return PixivFixtures.authorIllusts([Work(id: 8801)], authorID: "3344", authorName: "Sora")
            }
            if url.path.hasPrefix("/ajax/search/") {
                return PixivFixtures.search([PixivFixtures.searchEntry(Work(id: 7201))], total: 1, lastPage: 1)
            }
            return PixivFixtures.ranking([PixivFixtures.rankingEntry(Work(id: 301), rank: 1)], total: 1)
        })

        try await withPanel(pixivTransport: transport) { panel in
            let controller = panel.controller
            let pixiv = panel.pixiv
            let defaults = panel.defaults
            let model = controller.pixivBrowser

            let gateSunset = PixivGate()
            let gateForest = PixivGate()
            let gateDesert = PixivGate()
            var cancelledTexts: [String] = []

            model.searchTranslator = PixivSearchTranslator(
                defaults: defaults,
                translate: { text, _, target in
                    XCTAssertEqual(target, PixivSearchTranslator.japanese)
                    do {
                        switch text {
                        case "sunset":
                            try await gateSunset.pass()
                            return "夕焼け"
                        case "forest":
                            try await gateForest.pass()
                            return "森"
                        case "desert":
                            try await gateDesert.pass()
                            return "砂漠"
                        case "ocean":
                            return "海"
                        default:
                            return text
                        }
                    } catch is CancellationError {
                        cancelledTexts.append(text)
                        throw CancellationError()
                    }
                },
                appLanguage: { .english })

            // (a) Rapid search A -> B cancels A and never applies A after B.
            model.setText("sunset")
            let taskA = model.submit()
            try await waitUntil { gateSunset.waiting == 1 }

            model.setText("ocean")
            let taskB = model.submit()
            await taskA.value
            await taskB.value
            try await waitUntil { pixiv.hasLoaded && !pixiv.isLoading }

            XCTAssertTrue(cancelledTexts.contains("sunset"))
            XCTAssertEqual(pixiv.query.text, "ocean")
            XCTAssertEqual(controller.pixivBrowse.translation?.japanese, "海")
            XCTAssertFalse(transport.requests.contains { $0.path.contains("夕焼け") || $0.path.contains("sunset") })
            XCTAssertTrue(transport.requests.contains { $0.path == "/ajax/search/illustrations/海" })

            // (b) Opening an Author while a translation is in flight cancels it and never clobbers Author.
            let gateAuthorRace = PixivGate()
            model.searchTranslator = PixivSearchTranslator(
                defaults: defaults,
                translate: { text, _, _ in
                    do {
                        if text == "mountain" {
                            try await gateAuthorRace.pass()
                            return "山"
                        }
                        if text == "forest" {
                            try await gateForest.pass()
                            return "森"
                        }
                        if text == "desert" {
                            try await gateDesert.pass()
                            return "砂漠"
                        }
                        return text
                    } catch is CancellationError {
                        cancelledTexts.append(text)
                        throw CancellationError()
                    }
                },
                appLanguage: { .english })

            model.setText("mountain")
            let staleMountain = model.submit()
            try await waitUntil { gateAuthorRace.waiting == 1 }

            await model.openAuthor(id: "3344", name: "Sora")?.value
            await staleMountain.value
            try await waitUntil {
                controller.pixivBrowse.scope == .author(id: "3344", name: "Sora") && !pixiv.isLoading
            }
            XCTAssertTrue(cancelledTexts.contains("mountain"))
            XCTAssertEqual(controller.pixivBrowse.scope, .author(id: "3344", name: "Sora"))
            XCTAssertEqual(model.draft.text, "")
            XCTAssertFalse(transport.requests.contains { $0.path.contains("山") || $0.path.contains("mountain") })
            XCTAssertTrue(controller.pixivBrowse.canGoBack)

            // (c) Clicking Back while a translation is in flight cancels it and preserves restored state.
            model.setText("forest")
            let staleForest = model.submit()
            try await waitUntil { gateForest.waiting == 1 }

            await model.goBack().value
            await staleForest.value
            try await waitUntil { controller.pixivBrowse.scope == .explore && !pixiv.isLoading }
            XCTAssertTrue(cancelledTexts.contains("forest"))
            XCTAssertEqual(pixiv.query.text, "ocean")
            XCTAssertFalse(transport.requests.contains { $0.path.contains("森") || $0.path.contains("forest") })

            // (d) Switching scope while a translation is in flight cancels it and keeps Bookmarks.
            model.setText("desert")
            let staleDesert = model.submit()
            try await waitUntil { gateDesert.waiting == 1 }

            await model.open(tab: .bookmarks).value
            await staleDesert.value
            XCTAssertTrue(cancelledTexts.contains("desert"))
            XCTAssertEqual(controller.pixivBrowse.scope, .bookmarks(.public))
            XCTAssertEqual(PixivEmptyState.make(controller.pixivBrowse), .signInRequired(.bookmarks))
            XCTAssertFalse(transport.requests.contains { $0.path.contains("砂漠") || $0.path.contains("desert") })

            // (e) Leaving Author via tag search clears the Back stack (no orphaned Back on Explore).
            await model.open(tab: .explore).value
            try await waitUntil { controller.pixivBrowse.scope == .explore && !pixiv.isLoading }
            await model.openAuthor(id: "3344", name: "Sora")?.value
            try await waitUntil {
                controller.pixivBrowse.scope == .author(id: "3344", name: "Sora") && !pixiv.isLoading
            }
            XCTAssertTrue(controller.pixivBrowse.canGoBack)

            await model.searchTag("sky").value
            try await waitUntil { controller.pixivBrowse.scope == .explore && !pixiv.isLoading }
            XCTAssertFalse(controller.pixivBrowse.canGoBack)
        }
    }

    func testAuthorRefreshDeterministicallyClearsCacheBeforeRefetching() async throws {
        final class HitCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() -> Int { lock.withLock { value += 1; return value } }
            var current: Int { lock.withLock { value } }
        }
        let profileAllHits = HitCounter()
        let transport = PixivFixtureTransport { url in
            if url.path == "/ajax/user/3344/profile/all" {
                let hit = profileAllHits.increment()
                return PixivFixtures.authorProfileAll(illustIDs: hit == 1 ? [101] : [202, 101])
            }
            if url.path == "/ajax/user/3344/profile/illusts" {
                let hit = profileAllHits.current
                let works = hit == 1 ? [Work(id: 101)] : [Work(id: 202), Work(id: 101)]
                return PixivFixtures.authorIllusts(works, authorID: "3344", authorName: "Sora")
            }
            return PixivFixtures.ranking([PixivFixtures.rankingEntry(Work(id: 1), rank: 1)], total: 1)
        }

        let service = PixivService(transport: transport, minimumInterval: .zero)
        let store = PixivStore(service: service, sessions: PixivMemorySessionStore())

        store.openAuthor(id: "3344", name: "Sora")
        try await waitUntil { store.hasLoaded && !store.isLoading }
        XCTAssertEqual(store.works.map(\.id), ["101"])
        XCTAssertEqual(profileAllHits.current, 1)

        // Refresh must clear `PixivService`'s author cache synchronously on the actor BEFORE
        // reading `authorIDCache`, so `/profile/all` runs first and returns the updated works.
        store.apply(store.query, refresh: true)
        try await waitUntil { store.hasLoaded && !store.isLoading }
        XCTAssertEqual(profileAllHits.current, 2)
        XCTAssertEqual(store.works.map(\.id), ["202", "101"])
        let lastTwoPaths = transport.requests.suffix(2).map(\.path)
        XCTAssertEqual(lastTwoPaths, ["/ajax/user/3344/profile/all", "/ajax/user/3344/profile/illusts"])
    }

    func testBrowseStateUpdatesScopeAndSignInRequirementImmediatelyWhileLoading() async throws {
        final class ScopedGateTransport: PixivTransport, @unchecked Sendable {
            private let lock = NSLock()
            let fixture: PixivFixtureTransport
            private var gates: [String: PixivGate] = [:]

            init(fixture: PixivFixtureTransport) { self.fixture = fixture }

            func hold(pathPrefix: String, with gate: PixivGate?) {
                lock.withLock { gates[pathPrefix] = gate }
            }

            func data(from url: URL, session: String?) async throws -> Data {
                let matchingGate: PixivGate? = lock.withLock {
                    gates.first { url.path.hasPrefix($0.key) }?.value
                }
                if let matchingGate { try await matchingGate.pass() }
                return try await fixture.data(from: url, session: session)
            }

            func image(
                from url: URL, limit: Int, progress: @escaping @Sendable (Int64, Int64?) -> Void
            ) async throws -> Data {
                try await fixture.image(from: url, limit: limit, progress: progress)
            }
        }

        let fixture = PixivFixtureTransport(respondingToSession: { url, session in
            if url.path == "/touch/ajax/user/self/status" {
                return PixivFixtures.status(signedIn: session == PixivFixtures.session)
            }
            if url.path == "/ajax/user/3344/profile/all" {
                return PixivFixtures.authorProfileAll(illustIDs: [501])
            }
            if url.path == "/ajax/user/3344/profile/illusts" {
                return PixivFixtures.authorIllusts([Work(id: 501)], authorID: "3344", authorName: "Sora")
            }
            if url.path == "/ajax/user/31415926/illusts/bookmarks" {
                return PixivFixtures.bookmarks([PixivFixtures.searchEntry(Work(id: 601))], total: 1)
            }
            return PixivFixtures.ranking([PixivFixtures.rankingEntry(Work(id: 301), rank: 1)], total: 1)
        })
        let transport = ScopedGateTransport(fixture: fixture)
        let sessions = PixivMemorySessionStore(PixivFixtures.session)
        let store = PixivStore(
            service: PixivService(transport: transport, minimumInterval: .zero),
            sessions: sessions)

        // 1. Load Explore, then transition Explore -> Author with Author fetch held mid-load.
        store.apply(PixivQuery())
        try await waitUntil { store.hasLoaded && !store.isLoading }

        let authorGate = PixivGate()
        transport.hold(pathPrefix: "/ajax/user/3344/", with: authorGate)
        store.openAuthor(id: "3344", name: "Sora")
        try await waitUntil { authorGate.waiting == 1 }

        let midAuthor = PixivBrowseState(store)
        XCTAssertTrue(midAuthor.isLoading)
        XCTAssertEqual(midAuthor.scope, .author(id: "3344", name: "Sora"))
        XCTAssertFalse(midAuthor.requiresSignIn)
        XCTAssertEqual(PixivEmptyState.make(midAuthor), .loading)

        authorGate.open()
        transport.hold(pathPrefix: "/ajax/user/3344/", with: nil)
        try await waitUntil { store.hasLoaded && !store.isLoading }

        // 2. Sign in, load Bookmarks, then transition Bookmarks -> Explore with Explore held mid-load.
        store.signIn(obtainingSessionWith: { PixivFixtures.session })
        try await waitUntil { store.isSignedIn && !store.isSigningIn }
        store.openScope(.bookmarks(.public))
        try await waitUntil {
            store.committedQuery?.scope == .bookmarks(.public) && store.hasLoaded && !store.isLoading
        }

        let exploreGate = PixivGate()
        transport.hold(pathPrefix: "/ranking.php", with: exploreGate)
        store.openScope(.explore)
        try await waitUntil { exploreGate.waiting == 1 }

        let midExplore = PixivBrowseState(store)
        XCTAssertTrue(midExplore.isLoading)
        XCTAssertEqual(midExplore.scope, .explore)
        XCTAssertFalse(midExplore.requiresSignIn)
        XCTAssertEqual(PixivEmptyState.make(midExplore), .loading)

        exploreGate.open()
        transport.hold(pathPrefix: "/ranking.php", with: nil)
        try await waitUntil { store.hasLoaded && !store.isLoading }
        XCTAssertEqual(PixivBrowseState(store).scope, .explore)
    }
}

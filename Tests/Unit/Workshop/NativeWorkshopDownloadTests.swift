import XCTest
@testable import WallpaperMachine

/// Workshop downloads signed in with a QR code: the app's own Steam client, a scripted Steam,
/// the real queue and the real import into a temporary library.
@MainActor
final class NativeWorkshopDownloadTests: DownloaderTestCase {
  private let itemID: UInt64 = 3_521_337_568

  private func item() -> WorkshopItem {
    WorkshopItem(
      id: String(itemID), title: "Lucy", creator: "Test", summary: "", previewURL: nil,
      tags: ["Video"], size: 0, subscriptions: 0)
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("NativeDownload-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
    return root
  }

  func testAQRSignedInDownloadArrivesInTheLibraryWithoutAnyPrompt() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let steam = try FakeSteam(item: itemID, files: [
      "project.json": Data(#"{"type":"video","file":"movie.mp4"}"#.utf8),
      "movie.mp4": Data("frames".utf8),
    ])
    let session = steam.session(store: MemorySteamTokenStore(SteamTestToken.token()))
    await session.restore()
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider(),
      downloadRegion: { .steamsChoice })
    var imported = false
    manager.startNative(item: item(), session: session, library: root.appendingPathComponent("Library")) {
      imported = true
    }
    let job = try XCTUnwrap(manager.download(for: String(itemID)))
    XCTAssertNil(job.steamCMD, "a QR sign-in never starts SteamCMD")
    try await waitUntil { !manager.isRunning }

    XCTAssertNil(job.errorMessage)
    XCTAssertTrue(job.worker.completedSuccessfully)
    XCTAssertTrue(imported)
    XCTAssertNil(job.worker.prompt)
    let folder = root.appendingPathComponent("Library/\(itemID)")
    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("movie.mp4")), Data("frames".utf8))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0.hasPrefix(WorkshopDownloader.stagingPrefix) }
    XCTAssertEqual(leftovers, [], "staging is removed once the item is in the library")
  }

  func testDownloadsShareOneSteamConnection() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let steam = try FakeSteam(item: itemID, files: [
      "project.json": Data(#"{"type":"video","file":"movie.mp4"}"#.utf8), "movie.mp4": Data("frames".utf8),
    ])
    let session = steam.session(store: MemorySteamTokenStore(SteamTestToken.token()))
    await session.restore()
    _ = try await session.contentClient()
    _ = try await session.contentClient()
    XCTAssertEqual(steam.connectionsOpened, 1)
    session.release()
    session.release()
  }

  func testASignInSteamNoLongerAcceptsIsForgottenAndTheJobSaysSo() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let steam = try FakeSteam(item: itemID, files: ["project.json": Data("{}".utf8)])
    steam.logOnResult = 5
    let store = MemorySteamTokenStore(SteamTestToken.token())
    let session = steam.session(store: store)
    await session.restore()
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider(),
      downloadRegion: { .steamsChoice })
    manager.startNative(item: item(), session: session, library: root.appendingPathComponent("Library")) {}
    let job = try XCTUnwrap(manager.download(for: String(itemID)))
    try await waitUntil { !manager.isRunning }

    XCTAssertEqual(job.errorMessage, SteamNativeSession.Failure.signInExpired.localizedDescription)
    XCTAssertFalse(session.isSignedIn)
    XCTAssertNil(store.token, "a token Steam refused is removed from the keychain")
  }

  func testDownloadsWaitingOnTheSameLogOnAllLearnTheSignInExpired() async throws {
    let steam = try FakeSteam(item: itemID, files: [:])
    steam.logOnResult = 5
    let store = MemorySteamTokenStore(SteamTestToken.token())
    let session = steam.session(store: store)
    await session.restore()

    // Both start before either logon answers, so the second joins the first.
    let downloads = [Task { try await session.contentClient() }, Task { try await session.contentClient() }]
    for download in downloads {
      do {
        _ = try await download.value
        XCTFail("expected the refusal")
      } catch {
        XCTAssertEqual(error as? SteamNativeSession.Failure, .signInExpired)
      }
    }
    XCTAssertEqual(steam.connectionsOpened, 1, "the second download joined the first logon")
    XCTAssertNil(store.token)
  }

  func testAPausedDownloadStopsWaitingForASilentLogOn() async throws {
    let steam = try FakeSteam(item: itemID, files: [:])
    steam.answersLogOn = false
    let session = steam.session(store: MemorySteamTokenStore(SteamTestToken.token()))
    await session.restore()

    let waiting = Task { try await session.contentClient() }
    try await waitUntil { steam.connectionsOpened == 1 }
    let clock = ContinuousClock()
    let cancelled = clock.now
    waiting.cancel()
    do {
      _ = try await waiting.value
      XCTFail("expected the wait to end with the cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    XCTAssertLessThan(clock.now - cancelled, .seconds(2), "the scripted logon only times out after 5 seconds")
    XCTAssertTrue(session.isSignedIn, "a paused download is no reason to forget the sign-in")
  }

  func testAnAccountWithoutWallpaperEngineIsToldSoBeforeAnyContentIsFetched() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let steam = try FakeSteam(item: itemID, files: ["project.json": Data("{}".utf8)])
    steam.depotKeyResult = 15
    let session = steam.session(store: MemorySteamTokenStore(SteamTestToken.token()))
    await session.restore()
    let manager = WorkshopDownloadManager(
      sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider(),
      downloadRegion: { .steamsChoice })
    manager.startNative(item: item(), session: session, library: root.appendingPathComponent("Library")) {}
    let job = try XCTUnwrap(manager.download(for: String(itemID)))
    try await waitUntil { !manager.isRunning }

    XCTAssertEqual(job.worker.wallpaperEngineOwnership, .notOwned)
    XCTAssertFalse(job.worker.completedSuccessfully)
    XCTAssertEqual(steam.fetcher.requests, [], "neither the manifest nor a chunk is fetched")
  }

  func testAQRSignInLetsARequestRefusedForItsAccountGoAgain() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let steam = try FakeSteam(item: itemID, files: [:])
    var challenge = SteamProto.Writer()
    challenge.varint(1, 7)
    challenge.string(2, "https://s.team/q/1/7")
    challenge.bytes(3, Data([1]))
    challenge.fixed32(4, Float(1).bitPattern)
    steam.api.reply("BeginAuthSessionViaQR", challenge)
    var approved = SteamProto.Writer()
    approved.string(3, SteamTestToken.jwt())
    approved.string(6, "someone")
    steam.api.reply("PollAuthSessionStatus", approved)
    let session = steam.session(store: MemorySteamTokenStore())
    let requests = root.appendingPathComponent("Downloads/workshop-requests.json")
    try FileManager.default.createDirectory(at: requests.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode([
      WorkshopDownloadRequest(
        id: String(itemID), item: item(), account: "", rememberSession: true, includesResources: false,
        refused: true)
    ]).write(to: requests)
    let store = WorkshopStore(
      downloader: WorkshopDownloadManager(
        sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider(),
        downloadRegion: { .steamsChoice }),
      supportDirectory: root, defaults: try TemporaryDefaults.make(for: self).defaults,
      runtimeProvider: ShellRuntimeProvider(), nativeSession: session)

    session.beginQRSignIn()
    try await waitUntil { session.isSignedIn }

    let request = try XCTUnwrap(store.downloadRequests.first)
    XCTAssertFalse(request.refused, "the QR sign-in answers what the account form was waiting for")
    XCTAssertEqual(store.stage(for: request), .ready)
    await store.steamCMDSetup.shutdown()
  }

  func testNativeFailuresReadAsAFewPlainPhrases() {
    let unreachable = NativeWorkshopDownloader.message(for: URLError(.notConnectedToInternet))
    XCTAssertEqual(NativeWorkshopDownloader.message(for: SteamCMConnection.Failure.timedOut("the sign-in")), unreachable)
    XCTAssertEqual(NativeWorkshopDownloader.message(for: SteamWebAPIError(method: "x", status: 502, eresult: nil)), unreachable)

    let unavailable = NativeWorkshopDownloader.message(for: SteamContentClient.Failure.itemUnavailable(1, eresult: 9))
    XCTAssertEqual(NativeWorkshopDownloader.message(for: SteamContentClient.Failure.wrongApp(1, app: 480)), unavailable)
    XCTAssertEqual(NativeWorkshopDownloader.message(for: SteamContentClient.Failure.notDepotContent(1)), unavailable)

    let servers = NativeWorkshopDownloader.message(for: SteamContentClient.Failure.noContentServers)
    XCTAssertEqual(
      NativeWorkshopDownloader.message(for: SteamContentClient.Failure.http(status: 503, url: URL(string: "https://cdn.test/")!)),
      servers)

    let mismatch = NativeWorkshopDownloader.message(for: SteamContentClient.Failure.chunkMismatch("ab"))
    XCTAssertEqual(NativeWorkshopDownloader.message(for: SteamProto.DecodingError(reason: "bad")), mismatch)

    XCTAssertEqual(
      NativeWorkshopDownloader.message(
        for: SteamCMConnection.Failure.requestFailed(SteamContentClient.itemDetailsMethod, eresult: 9)),
      unavailable)
    XCTAssertEqual(
      NativeWorkshopDownloader.message(
        for: SteamCMConnection.Failure.requestFailed("the manifest request code", eresult: 2)),
      servers)

    // Steam answered, so none of these is the internet connection's fault.
    let limited = NativeWorkshopDownloader.message(for: SteamCMConnection.Failure.logOnRefused(eresult: 84))
    let refused = NativeWorkshopDownloader.message(for: SteamCMConnection.Failure.logOnRefused(eresult: 2))
    let ended = NativeWorkshopDownloader.message(for: SteamCMConnection.Failure.loggedOff(eresult: 6))

    let phrases = [unreachable, unavailable, servers, mismatch, limited, refused, ended]
    XCTAssertEqual(Set(phrases).count, phrases.count)
    for message in phrases {
      XCTAssertFalse(message.contains("EResult"), message)
    }
    XCTAssertTrue(NativeWorkshopDownloader.meansNotOwned(
      SteamCMConnection.Failure.requestFailed(SteamContentClient.depotKeyRequest, eresult: 15)))
    XCTAssertFalse(NativeWorkshopDownloader.meansNotOwned(
      SteamCMConnection.Failure.requestFailed(SteamContentClient.depotKeyRequest, eresult: 84)),
      "a rate limit says nothing about ownership")
    XCTAssertFalse(NativeWorkshopDownloader.meansNotOwned(
      SteamCMConnection.Failure.requestFailed(SteamContentClient.itemDetailsMethod, eresult: 15)))
    XCTAssertTrue(
      NativeWorkshopDownloader.message(for: SteamCMConnection.Failure.requestFailed("the depot key", eresult: 15))
        .contains("does not own Wallpaper Engine"))
    XCTAssertTrue(
      NativeWorkshopDownloader.message(for: SteamContentClient.Failure.insufficientSpace(needed: 2_000_000_000, available: 1_000))
        .hasPrefix("Not enough free disk space"))
    XCTAssertEqual(NativeWorkshopDownloader.message(for: SteamNativeSession.Failure.signInExpired),
                   SteamNativeSession.Failure.signInExpired.localizedDescription)
  }

  func testAQRSignInSkipsSteamCMDSetupAndTheAccountName() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let steam = try FakeSteam(item: itemID, files: [:])
    let session = steam.session(store: MemorySteamTokenStore(SteamTestToken.token()))
    await session.restore()
    let store = WorkshopStore(
      downloader: WorkshopDownloadManager(
        sessionDirectory: root.appendingPathComponent("SteamSession"), runtimeProvider: ShellRuntimeProvider(),
        downloadRegion: { .steamsChoice }),
      supportDirectory: root, defaults: try TemporaryDefaults.make(for: self).defaults,
      runtimeProvider: ShellRuntimeProvider(), nativeSession: session)
    let request = WorkshopDownloadRequest(
      id: String(itemID), item: item(), account: "", rememberSession: true, includesResources: false)
    XCTAssertNil(store.steamCMDSetup.selectedRuntime)
    XCTAssertEqual(store.stage(for: request), .ready)

    session.signOut()
    XCTAssertEqual(store.stage(for: request), .setup, "without the QR sign-in, SteamCMD is needed again")
    await store.steamCMDSetup.shutdown()
  }

  func testAnApprovedQRSignInIsSavedAndAnExpiredOneIsNotRestored() async throws {
    let steam = try FakeSteam(item: itemID, files: [:])
    var challenge = SteamProto.Writer()
    challenge.varint(1, 7)
    challenge.string(2, "https://s.team/q/1/7")
    challenge.bytes(3, Data([1]))
    challenge.fixed32(4, Float(1).bitPattern)
    steam.api.reply("BeginAuthSessionViaQR", challenge)
    var approved = SteamProto.Writer()
    approved.string(3, SteamTestToken.jwt())
    approved.string(6, "someone")
    steam.api.reply("PollAuthSessionStatus", approved)
    let store = MemorySteamTokenStore()
    let session = steam.session(store: store)
    var changes = 0
    session.onChange = { changes += 1 }

    session.beginQRSignIn()
    try await waitUntil { session.isSignedIn }
    XCTAssertEqual(session.accountName, "someone")
    XCTAssertEqual(store.token?.accountName, "someone")
    XCTAssertEqual(session.qr, .idle)
    XCTAssertEqual(changes, 1)

    session.signOut()
    XCTAssertNil(store.token)
    let expired = MemorySteamTokenStore(
      try SteamRefreshToken(SteamTestToken.jwt(expires: Date(timeIntervalSinceNow: -60)), accountName: "old"))
    let restored = steam.session(store: expired)
    await restored.restore()
    XCTAssertFalse(restored.isSignedIn)
    XCTAssertNil(expired.token)
  }
}

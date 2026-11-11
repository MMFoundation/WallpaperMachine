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

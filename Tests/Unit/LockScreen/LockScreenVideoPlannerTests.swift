import AVFoundation
import XCTest
import WallpaperMedia

@testable import WallpaperMachine

/// Which path draws a plain video on the lock screen, and what happens when the native player
/// cannot open the clip. No real lock screen and no decoding: the decision is a function of the
/// configuration and of what admission says about the file.
final class LockScreenVideoPlannerTests: XCTestCase {
  private func scene(
    file: String? = "clip.mp4", fps: UInt32 = 30, web: String? = nil,
    projectPath: String = "revisions/abc/project.json"
  ) -> LockScreenScene {
    LockScreenScene(
      displayID: 1, title: "t", projectPath: projectPath, assetsPath: "revisions/abc",
      previewPath: nil, fps: fps, scalingMode: 3, scalingFactor: 1, propertiesJSON: nil,
      paused: false, webEntryFile: web, nativeVideoFile: file)
  }

  private struct Missing: Error, LocalizedError {
    var errorDescription: String? { "no such file" }
  }

  private func decide(
    _ scene: LockScreenScene, enabled: Bool = true,
    admission: @escaping (URL) async -> NativeVideoRefusal? = { _ in nil },
    resolved: @escaping (String) throws -> URL = { URL(fileURLWithPath: "/exchange/" + $0) },
    openWebM: @escaping (URL) -> WebMFile? = { _ in nil }
  ) async -> LockScreenVideoPath {
    await LockScreenVideoPlanner.decide(
      scene: scene, enabled: enabled, resolve: resolved, admission: admission, openWebM: openWebM)
  }

  private func webMFile() throws -> WebMFile {
    guard case .success(let file) = WebMOpening.open(data: WebMFixture.vp9) else {
      throw XCTSkip("the embedded WebM no longer opens")
    }
    return file
  }

  func testAMatroskaOrWebMFileAVFoundationCannotOpenIsPlayedByTheWebMPlayerWhenItsReaderTakesIt() async throws {
    let file = try webMFile()
    var opened: [URL] = []
    let path = await decide(
      scene(file: "clip.webm"), admission: { _ in .notPlayable("asset reports itself unplayable") },
      openWebM: { url in
        opened.append(url)
        return file
      })
    XCTAssertEqual(path, .webM(URL(fileURLWithPath: "/exchange/revisions/abc/clip.webm"), file))
    XCTAssertTrue(path.isNative)
    XCTAssertEqual(opened, [URL(fileURLWithPath: "/exchange/revisions/abc/clip.webm")])
  }

  func testAFileTheWebMReaderDoesNotTakeKeepsAVFoundationsRefusalAndGoesToTheSceneEngine() async {
    let path = await decide(
      scene(file: "clip.webm"), admission: { _ in .notPlayable("asset reports itself unplayable") },
      openWebM: { _ in nil })
    XCTAssertEqual(path, .sceneEngine(reason: "asset is not playable: asset reports itself unplayable"))
  }

  func testOnlyAnUnplayableAnswerIsPassedToTheWebMReader() async throws {
    let file = try webMFile()
    for refusal in [NativeVideoRefusal.preparationFailed("busy"), .playbackFailed("decoder")] {
      var asked = false
      let path = await decide(scene(), admission: { _ in refusal }, openWebM: { _ in
        asked = true
        return file
      })
      XCTAssertFalse(path.isNative, "\(refusal)")
      XCTAssertFalse(asked, "a read that failed or a decoder that gave up says nothing about the container")
    }
  }

  func testAClipTheAppAskedTheNativePlayerForIsPlayedByAVFoundationWhenAdmissionAccepts() async {
    var asked: [URL] = []
    let path = await decide(scene(fps: 24), admission: { url in
      asked.append(url)
      return nil
    })
    XCTAssertEqual(path, .avFoundation(URL(fileURLWithPath: "/exchange/revisions/abc/clip.mp4")))
    XCTAssertTrue(path.isNative)
    XCTAssertEqual(asked, [URL(fileURLWithPath: "/exchange/revisions/abc/clip.mp4")],
      "the rule is about the file: the frame rate the lock screen was given takes no part")
  }

  func testAClipTheAppDidNotAskTheNativePlayerForStaysWithTheSceneEngine() async {
    var admissionAsked = false
    let path = await decide(scene(file: nil), admission: { _ in
      admissionAsked = true
      return nil
    })
    XCTAssertEqual(path, .sceneEngine(reason: nil))
    XCTAssertFalse(admissionAsked, "nothing is opened for a scene that never asked")
  }

  func testAWebPageNeverTakesTheNativePlayer() async {
    let path = await decide(scene(web: "index.html"))
    XCTAssertEqual(path, .sceneEngine(reason: nil))
  }

  func testAClipAVFoundationCannotOpenFallsBackToTheSceneEngineWithTheReason() async {
    for refusal in [
      NativeVideoRefusal.notPlayable("asset reports itself unplayable"),
      .preparationFailed("the file could not be read"),
      .playbackFailed("decoder error"),
    ] {
      let path = await decide(scene(), admission: { _ in refusal })
      XCTAssertEqual(path, .sceneEngine(reason: refusal.reason), "\(refusal)")
      XCTAssertFalse(path.isNative)
    }
  }

  func testAClipThatIsNotThereFallsBackInsteadOfFailingTheSurface() async {
    let path = await decide(scene(), resolved: { _ in throw Missing() })
    guard case .sceneEngine(let reason?) = path else { return XCTFail("\(path)") }
    XCTAssertTrue(reason.contains("no such file"))
  }

  func testAClipThePlayerAlreadyFailedOnIsNotTriedAgain() async {
    var admissionAsked = false
    let path = await decide(scene(), enabled: false, admission: { _ in
      admissionAsked = true
      return nil
    })
    guard case .sceneEngine(let reason?) = path else { return XCTFail("\(path)") }
    XCTAssertFalse(reason.isEmpty)
    XCTAssertFalse(admissionAsked)
  }

  func testAFileOutsideTheProjectIsNeverResolved() async {
    for file in ["../other/clip.mp4", "/etc/hosts", "a/../b.mp4", "./clip.mp4", "a//b.mp4", ""] {
      var resolved = false
      let path = await decide(scene(file: file), resolved: { _ in
        resolved = true
        return URL(fileURLWithPath: "/x")
      })
      XCTAssertFalse(path.isNative, file)
      XCTAssertFalse(resolved, file)
    }
  }

  func testTheMediaPathLiesNextToTheProjectFile() {
    XCTAssertEqual(
      LockScreenVideoPlanner.mediaPath(of: scene(file: "media/clip.mp4")),
      "revisions/abc/media/clip.mp4")
    XCTAssertNil(LockScreenVideoPlanner.mediaPath(of: scene(projectPath: "project.json")))
  }

  // MARK: The player's own failure

  /// A file AVFoundation cannot play fails `prepare()`, which is what sends the surface to the
  /// scene engine. Nothing is decoded: the open itself is refused.
  @MainActor
  func testAFileThatIsNotAVideoFailsPrepareSoTheSurfaceFallsBack() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("lock-screen-video-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let garbage = directory.appendingPathComponent("clip.webm")
    try Data("not a movie".utf8).write(to: garbage)
    for url in [garbage, directory.appendingPathComponent("missing.mp4")] {
      let player = LockScreenVideoPlayer(
        url: url, mode: .fill, factor: 1, viewport: CGSize(width: 100, height: 100),
        backingScale: 1)
      do {
        _ = try await player.prepare()
        XCTFail("\(url.lastPathComponent) should not play")
      } catch let failure as LockScreenVideoPlayer.Failure {
        guard case .unplayable = failure else { return XCTFail("\(failure)") }
      }
      player.stop()
    }
  }

  @MainActor
  func testAStoppedPlayerFailsPrepareAsCancelledNotAsUnplayable() async throws {
    let player = LockScreenVideoPlayer(
      url: URL(fileURLWithPath: "/nonexistent.mp4"), mode: .fill, factor: 1,
      viewport: CGSize(width: 100, height: 100), backingScale: 1)
    player.stop()
    do {
      _ = try await player.prepare()
      XCTFail("a stopped player does not play")
    } catch {
      XCTAssertNotNil(error)
    }
  }

  // MARK: A failure is held against the clip, not the surface

  func testAFailureIsHeldAgainstTheClipItWasAboutAndNotAgainstALaterOne() {
    var memory = LockScreenNativeVideoMemory()
    let first = scene(file: "a.mp4")
    XCTAssertTrue(memory.allows(first), "nothing has failed yet")
    memory.recordFailure(of: first)
    XCTAssertFalse(memory.allows(first), "the clip that failed does not retry in a loop")
    XCTAssertFalse(memory.allows(scene(file: "a.mp4", fps: 60)), "a new frame rate is the same clip")
    XCTAssertTrue(memory.allows(scene(file: "b.mp4")), "a different file tries the native player")
    XCTAssertTrue(
      memory.allows(scene(file: "a.mp4", projectPath: "revisions/def/project.json")),
      "a replaced revision of the file tries the native player")
    XCTAssertTrue(memory.allows(scene(file: nil)), "a scene that never asked is not held back")
  }

  func testTheMemoryFollowsTheLatestFailure() {
    var memory = LockScreenNativeVideoMemory()
    memory.recordFailure(of: scene(file: "a.mp4"))
    memory.recordFailure(of: scene(file: "b.mp4"))
    XCTAssertTrue(memory.allows(scene(file: "a.mp4")))
    XCTAssertFalse(memory.allows(scene(file: "b.mp4")))
  }

  // MARK: The native attempt has its own deadline

  private struct Hung: Error {}

  @MainActor
  func testAnAttemptThatNeverFinishesExpiresWhenTheClockSaysSoWithoutWaiting() async {
    var cancelled = false
    do {
      _ = try await LockScreenDeadline.run(
        within: .seconds(10), sleep: { _ in },
        operation: { () async throws -> Int in
          do { try await Task.sleep(for: .seconds(3600)) } catch {
            cancelled = true
            throw error
          }
          return 1
        })
      XCTFail("a hung attempt must not return")
    } catch let expired as LockScreenDeadline.Expired {
      XCTAssertEqual(expired.timeout, .seconds(10))
    } catch {
      XCTFail("\(error)")
    }
    // The operation is told to stop; it ends by itself shortly after.
    for _ in 0..<100 where !cancelled { await Task.yield() }
    XCTAssertTrue(cancelled)
  }

  @MainActor
  func testAnAttemptThatFinishesInTimeKeepsItsResultAndItsFailure() async throws {
    let value = try await LockScreenDeadline.run(
      within: .seconds(10), sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
      operation: { 7 })
    XCTAssertEqual(value, 7)
    do {
      _ = try await LockScreenDeadline.run(
        within: .seconds(10), sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        operation: { () async throws -> Int in throw Hung() })
      XCTFail("the operation's own failure is not a deadline")
    } catch {
      XCTAssertTrue(error is Hung)
    }
  }

  @MainActor
  func testCancellingTheCallerCancelsAnAttemptThatIsStillRunning() async {
    let attempt = Task { @MainActor in
      try await LockScreenDeadline.run(
        within: .seconds(10), sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        operation: { () async throws -> Int in
          try await Task.sleep(for: .seconds(3600))
          return 1
        })
    }
    await Task.yield()
    attempt.cancel()
    do {
      _ = try await attempt.value
      XCTFail("a cancelled attempt does not finish")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
  }

  func testTheNativeAttemptEndsWellInsideTheSurfacesFirstFrameDeadline() {
    XCTAssertLessThan(LockScreenDeadline.nativeAttempt, .seconds(30))
  }

  // MARK: A failure that beats the handler is not lost

  @MainActor
  private func idlePlayer() -> LockScreenVideoPlayer {
    LockScreenVideoPlayer(
      url: URL(fileURLWithPath: "/nonexistent.mp4"), mode: .fill, factor: 1,
      viewport: CGSize(width: 100, height: 100), backingScale: 1)
  }

  @MainActor
  func testAFailureBeforeTheHandlerIsAssignedIsDeliveredWhenItIs() {
    let player = idlePlayer()
    defer { player.stop() }
    player.fail("item failed")
    player.fail("looper failed too")
    var heard: [String] = []
    player.onFailure = { heard.append($0) }
    XCTAssertEqual(heard, ["item failed"], "the first reason, once")
    player.onFailure = { heard.append($0) }
    player.fail("again")
    XCTAssertEqual(heard, ["item failed"], "a failure is reported once")
  }

  @MainActor
  func testAFailureWithTheHandlerAlreadySetIsDeliveredAtOnceAndOnce() {
    let player = idlePlayer()
    defer { player.stop() }
    var heard: [String] = []
    player.onFailure = { heard.append($0) }
    player.fail("stalled")
    player.fail("stalled again")
    XCTAssertEqual(heard, ["stalled"])
  }

  @MainActor
  func testAStoppedPlayerHearsNoFailureAndHoldsNone() {
    let player = idlePlayer()
    player.fail("late")
    player.stop()
    var heard: [String] = []
    player.onFailure = { heard.append($0) }
    player.fail("later")
    XCTAssertEqual(heard, [])
  }
}

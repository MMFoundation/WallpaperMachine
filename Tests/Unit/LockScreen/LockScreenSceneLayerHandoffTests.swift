import XCTest

@testable import WallpaperMachine

final class LockScreenSceneLayerHandoffTests: XCTestCase {
  private let choice = #"{"version":1,"layers":[[17,true,0.75]]}"#

  private func scene(_ wallpaperID: String? = "desktop", displayID: UInt32 = 7) -> LockScreenScene {
    LockScreenScene(
      displayID: displayID, title: "Scene", projectPath: "project.json", assetsPath: "assets",
      fps: 30, scalingMode: 3, scalingFactor: 1, paused: false,
      desktopLayerStateWallpaperID: wallpaperID)
  }

  func testFirstReadyAndRetainedLockScreensTakeOneChoicePerPresentation() throws {
    let scene = scene()
    let config = LockScreenConfiguration(revision: "one", scenes: [scene])
    var handoff = LockScreenSceneLayerHandoff()
    var presentation = WallpaperPresentationAuthority.Request(role: .lockScreen, sessionLocked: true)
    func update(_ ready: Bool, content: LockScreenContent = .lockScreen) {
      handoff.update(scene: scene, content: content, configuration: config,
        presentation: presentation, rendererReady: ready)
    }
    update(false)
    XCTAssertNil(handoff.pendingRequest)
    update(true)
    let first = try XCTUnwrap(handoff.pendingRequest)
    XCTAssertEqual(first.revision, config.revision)
    XCTAssertEqual(first.displayID, scene.displayID)
    XCTAssertEqual(first.content, .lockScreen)
    update(true)
    XCTAssertEqual(handoff.pendingRequest, first)
    XCTAssertNil(handoff.takeState(from: [UUID(): choice]))
    XCTAssertEqual(handoff.takeState(from: [first.token: choice]), choice)
    update(true)
    XCTAssertNil(handoff.pendingRequest)
    XCTAssertNil(handoff.takeState(from: [first.token: choice]))

    presentation.sessionLocked = false
    presentation.presentedFor = .zero
    update(true, content: .desktop)
    XCTAssertNil(handoff.pendingRequest)
    presentation.sessionLocked = true
    update(true)
    let second = try XCTUnwrap(handoff.pendingRequest)
    XCTAssertNotEqual(first.token, second.token)
    XCTAssertNil(handoff.takeState(from: [first.token: choice]))
    update(false)
    XCTAssertNil(handoff.pendingRequest)
    XCTAssertNil(handoff.takeState(from: [second.token: choice]))
    update(true)
    XCTAssertNotEqual(try XCTUnwrap(handoff.pendingRequest).token, second.token)
  }

  func testSaverAndRevisionChangesRejectThePreviousLockScreenAnswer() throws {
    let scene = scene()
    var config = LockScreenConfiguration(revision: "one", scenes: [scene], screenSaverEnabled: true)
    var handoff = LockScreenSceneLayerHandoff()
    var presentation = WallpaperPresentationAuthority.Request(role: .lockScreen, sessionLocked: true)
    func update(_ content: LockScreenContent) {
      handoff.update(scene: scene, content: content, configuration: config,
        presentation: presentation, rendererReady: true)
    }
    update(.lockScreen)
    let lock = try XCTUnwrap(handoff.pendingRequest)
    presentation.presentationMode = "idle"
    update(.screenSaver)
    let saver = try XCTUnwrap(handoff.pendingRequest)
    XCTAssertEqual(saver.content, .screenSaver)
    XCTAssertNotEqual(saver.token, lock.token)
    config.revision = "two"
    update(.screenSaver)
    let next = try XCTUnwrap(handoff.pendingRequest)
    XCTAssertEqual(next.revision, "two")
    XCTAssertNotEqual(next.token, saver.token)
    XCTAssertNil(handoff.takeState(from: [lock.token: choice, saver.token: choice]))
    presentation.hostActivity = .suspended
    update(.screenSaver)
    XCTAssertNil(handoff.pendingRequest)
    XCTAssertNil(handoff.takeState(from: [next.token: choice]))
  }

  func testIndependentSourcesCannotInheritStateEvenWithIdenticalRendererAssets() throws {
    let following = scene()
    let independent = scene(nil)
    let config = LockScreenConfiguration(scenes: [following], screenSaverEnabled: true,
      screenSaverScenes: [independent])
    XCTAssertFalse(following.sharesRenderer(with: independent))
    var handoff = LockScreenSceneLayerHandoff()
    handoff.update(scene: following, content: .lockScreen, configuration: config,
      presentation: .init(role: .lockScreen, presentationMode: "locked"), rendererReady: true)
    let lock = try XCTUnwrap(handoff.pendingRequest)
    for scene in [following, independent] {
      handoff.update(scene: scene, content: .screenSaver, configuration: config,
        presentation: .init(role: .lockScreen, presentationMode: "idle"), rendererReady: true)
      XCTAssertNil(handoff.pendingRequest)
      XCTAssertNil(handoff.takeState(from: [lock.token: choice]))
    }
  }

  func testRetargetingTheSameWallpaperToAnotherDisplayRequiresItsOwnRendererAndAnswer() throws {
    let first = scene(displayID: 1), second = scene(displayID: 2)
    XCTAssertFalse(first.sharesRenderer(with: second))
    let config = LockScreenConfiguration(scenes: [first, second])
    var handoff = LockScreenSceneLayerHandoff()
    let locked = WallpaperPresentationAuthority.Request(role: .lockScreen, sessionLocked: true)
    handoff.update(scene: first, content: .lockScreen, configuration: config, presentation: locked, rendererReady: true)
    let firstToken = try XCTUnwrap(handoff.pendingRequest).token
    handoff.update(scene: second, content: .lockScreen, configuration: config, presentation: locked, rendererReady: true)
    let next = try XCTUnwrap(handoff.pendingRequest)
    XCTAssertEqual(next.displayID, 2)
    XCTAssertNotEqual(next.token, firstToken)
    XCTAssertNil(handoff.takeState(from: [firstToken: choice]))
  }

  func testConcurrentSurfacesForOneDisplayConsumeOnlyTheirOwnAnswers() throws {
    let scene = scene(), locked = WallpaperPresentationAuthority.Request(role: .lockScreen, sessionLocked: true)
    let config = LockScreenConfiguration(scenes: [scene])
    var first = LockScreenSceneLayerHandoff(), second = LockScreenSceneLayerHandoff()
    first.update(scene: scene, content: .lockScreen, configuration: config, presentation: locked, rendererReady: true)
    second.update(scene: scene, content: .lockScreen, configuration: config, presentation: locked, rendererReady: true)
    let firstToken = try XCTUnwrap(first.pendingRequest).token
    let secondToken = try XCTUnwrap(second.pendingRequest).token
    XCTAssertNotEqual(firstToken, secondToken)
    let otherChoice = #"{"version":1,"layers":[[17,false,0]]}"#
    let responses = [firstToken: choice, secondToken: otherChoice]
    XCTAssertEqual(first.takeState(from: responses), choice)
    XCTAssertEqual(second.takeState(from: responses), otherChoice)
  }

  func testUnshownSaverPreviewsVideosAndWebNeverRequestLayerState() {
    let following = scene()
    var video = following
    video.plainVideo = true
    var web = following
    web.webEntryFile = "index.html"
    for (scene, presentation) in [
      (following, WallpaperPresentationAuthority.Request(role: .lockScreen, presentedFor: .zero)),
      (following, .init(role: .preview, presentationMode: "idle")),
      (following, .init(role: .lockScreen, displaysAsleep: true, presentationMode: "idle")),
      (following, .init(role: .lockScreen, sessionOnConsole: false, presentationMode: "idle")),
      (video, .init(role: .lockScreen, presentationMode: "idle")),
      (web, .init(role: .lockScreen, presentationMode: "idle")),
    ] {
      let config = LockScreenConfiguration(scenes: [scene], lockScreenEnabled: false, screenSaverEnabled: true)
      var handoff = LockScreenSceneLayerHandoff()
      handoff.update(scene: scene, content: .screenSaver, configuration: config,
        presentation: presentation, rendererReady: true)
      XCTAssertNil(handoff.pendingRequest)
    }
  }

  func testOlderSceneAndDemandHaveNoLayerHandoff() throws {
    let data = Data(#"{"displayID":1,"title":"old","projectPath":"project.json","assetsPath":"assets","fps":30,"scalingMode":3,"scalingFactor":1,"paused":false}"#.utf8)
    let scene = try JSONDecoder().decode(LockScreenScene.self, from: data)
    var handoff = LockScreenSceneLayerHandoff()
    handoff.update(scene: scene, content: .lockScreen, configuration: .init(scenes: [scene]),
      presentation: .init(role: .lockScreen, sessionLocked: true), rendererReady: true)
    XCTAssertNil(handoff.pendingRequest)
    let demand = try JSONDecoder().decode(LockScreenLiveDemand.self,
      from: Data(#"{"processID":14,"needsMedia":true,"needsAudio":false}"#.utf8))
    XCTAssertTrue(demand.needsMedia)
    XCTAssertNil(demand.layerRequests)
  }

  func testExchangeAtomicallyReplacesMultipleAnswersAndRemovesTheLastOne() throws {
    let exchange = try temporaryExchange()
    defer { try? FileManager.default.removeItem(at: exchange) }
    let first = UUID(), second = UUID()
    let responses = [first: choice, second: #"{"version":1,"layers":[]}"#]
    try LockScreenSceneLayerExchange.write(responses, to: exchange)
    XCTAssertEqual(LockScreenSceneLayerExchange.read(from: exchange), responses)
    let url = exchange.appendingPathComponent(LockScreenSceneLayerExchange.fileName)
    let before = try Data(contentsOf: url)
    let oldReader = try FileHandle(forReadingFrom: url)
    defer { try? oldReader.close() }
    try LockScreenSceneLayerExchange.write([second: choice], to: exchange)
    XCTAssertEqual(try oldReader.readToEnd(), before)
    XCTAssertEqual(LockScreenSceneLayerExchange.read(from: exchange), [second: choice])
    try LockScreenSceneLayerExchange.write([:], to: exchange)
    try LockScreenSceneLayerExchange.write([:], to: exchange)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: exchange.path).isEmpty)
    XCTAssertTrue(LockScreenSceneLayerExchange.read(from: exchange).isEmpty)
  }

  func testExchangeRejectsMalformedOrOversizedInputWithoutReplacingAValidAnswer() throws {
    let exchange = try temporaryExchange()
    defer { try? FileManager.default.removeItem(at: exchange) }
    let token = UUID()
    let limit = LockScreenSceneLayerExchange.maximumStateBytes
    let full = choice + String(repeating: " ", count: limit - choice.utf8.count)
    try LockScreenSceneLayerExchange.write([token: full], to: exchange)
    let tooMany = Dictionary(uniqueKeysWithValues: (0...LockScreenSceneLayerExchange.maximumRequests).map { _ in (UUID(), choice) })
    for invalid in [[token: ""], [token: choice + "\0"], [token: full + "é"], tooMany] {
      XCTAssertThrowsError(try LockScreenSceneLayerExchange.write(invalid, to: exchange))
      XCTAssertEqual(LockScreenSceneLayerExchange.read(from: exchange), [token: full])
    }
    let url = exchange.appendingPathComponent(LockScreenSceneLayerExchange.fileName)
    for invalid in [
      ["not-a-uuid": choice], [token.uuidString: ""], [token.uuidString: full + " "],
      Dictionary(uniqueKeysWithValues: tooMany.map { ($0.key.uuidString, $0.value) }),
    ] {
      try JSONEncoder().encode(invalid).write(to: url, options: .atomic)
      XCTAssertTrue(LockScreenSceneLayerExchange.read(from: exchange).isEmpty)
    }
    var padded = try JSONEncoder().encode([token.uuidString: choice])
    padded.append(Data(repeating: 0x20, count: 16 * 1024 * 1024))
    try padded.write(to: url, options: .atomic)
    XCTAssertTrue(LockScreenSceneLayerExchange.read(from: exchange).isEmpty)
  }

  func testExchangeDoesNotFollowAReplacedFileOutsideItsDirectory() throws {
    let root = try temporaryExchange()
    defer { try? FileManager.default.removeItem(at: root) }
    let exchange = root.appendingPathComponent("exchange", isDirectory: true)
    try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: false)
    let token = UUID()
    try LockScreenSceneLayerExchange.write([token: choice], to: root)
    let name = LockScreenSceneLayerExchange.fileName
    try FileManager.default.createSymbolicLink(at: exchange.appendingPathComponent(name),
      withDestinationURL: root.appendingPathComponent(name))
    XCTAssertTrue(LockScreenSceneLayerExchange.read(from: exchange).isEmpty)
    try LockScreenSceneLayerExchange.write([:], to: exchange)
    XCTAssertEqual(LockScreenSceneLayerExchange.read(from: root), [token: choice])
  }

  private func temporaryExchange() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

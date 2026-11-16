import XCTest

@testable import WallpaperMachine

@MainActor
final class LockScreenAcquireRepliesTests: XCTestCase {
  func testReplacementPreservesTheAcquireUntilTheFinalSourceIsReady() {
    let replies = LockScreenAcquireReplies()
    var source = "desktop"
    var received: [String] = []
    var failures = 0
    replies.append { error in
      if error != nil { failures += 1 }
      else { received.append(source) }
    }
    let desktop = replies.begin()
    let locked = replies.begin()
    XCTAssertFalse(replies.complete(desktop, error: CancellationError()))
    XCTAssertTrue(replies.hasPending)
    XCTAssertTrue(received.isEmpty)
    source = "lock"
    XCTAssertTrue(replies.complete(locked, error: nil))
    XCTAssertEqual(received, ["lock"])
    XCTAssertEqual(failures, 0)
    XCTAssertFalse(replies.hasPending)
    XCTAssertFalse(replies.complete(desktop, error: nil))
    XCTAssertFalse(replies.complete(locked, error: nil))
    XCTAssertEqual(received, ["lock"])
  }

  func testRepeatedSourceSwitchesAndDuplicateAcquiresCompleteOnceEach() {
    let replies = LockScreenAcquireReplies()
    var results: [Int] = []
    replies.append { error in XCTAssertNil(error); results.append(1) }
    let first = replies.begin()
    replies.append { error in XCTAssertNil(error); results.append(2) }
    let second = replies.begin()
    let final = replies.begin()
    XCTAssertFalse(replies.complete(first, error: CancellationError()))
    XCTAssertFalse(replies.complete(second, error: CancellationError()))
    XCTAssertTrue(results.isEmpty)
    replies.complete(final, error: nil)
    XCTAssertEqual(results, [1, 2])
    replies.cancel()
    XCTAssertEqual(results, [1, 2])
  }

  func testClearCancelsPendingAcquiresAndLateReadinessCannotCompleteThemAgain() {
    let replies = LockScreenAcquireReplies()
    var cancellations = 0
    replies.append { error in
      XCTAssertTrue(error is CancellationError)
      cancellations += 1
    }
    let token = replies.begin()
    replies.cancel()
    XCTAssertFalse(replies.hasPending)
    XCTAssertEqual(cancellations, 1)
    XCTAssertFalse(replies.complete(token, error: nil))
    XCTAssertEqual(cancellations, 1)
  }

  func testPreparationFailureKeepsItsErrorAndDoesNotBecomeCancellation() {
    enum Failure: Error { case unavailable }
    let replies = LockScreenAcquireReplies()
    var failures = 0
    replies.append { error in
      XCTAssertTrue(error is Failure)
      failures += 1
    }
    replies.complete(replies.begin(), error: Failure.unavailable)
    replies.cancel()
    XCTAssertEqual(failures, 1)
  }

  func testSynchronousStartFailureIsRecordedBeforeRetirementAndRepliesExactlyOnce() {
    enum Failure: Error { case unavailable }
    let replies = LockScreenAcquireReplies()
    var registered = true
    var events: [String] = []
    var whenReady: ((Error?) -> Void)?
    replies.append { error in
      LockScreenReadiness.deliver(error: error, whenReady: { whenReady = $0 }) { reported in
        guard registered else { return }
        XCTAssertTrue(reported is Failure)
        events.append("record failure")
      }
      registered = false
      events.append("retire")
      XCTAssertTrue(error is Failure)
      events.append("reply failure")
    }
    let token = replies.begin()
    replies.complete(token, error: Failure.unavailable)
    replies.cancel()
    XCTAssertNil(whenReady, "an explicit startup error cannot wait for a frame that will never arrive")
    XCTAssertEqual(events, ["record failure", "retire", "reply failure"])
    XCTAssertFalse(replies.complete(token, error: nil))
    XCTAssertEqual(events, ["record failure", "retire", "reply failure"])
  }

  func testSuccessfulAcknowledgementWaitsForAFrameAndDropsAStaleSurface() {
    var frame: ((Error?) -> Void)?
    var registered = true
    var records = 0
    LockScreenReadiness.deliver(error: nil, whenReady: { frame = $0 }) { error in
      guard registered else { return }
      XCTAssertNil(error)
      records += 1
    }
    XCTAssertEqual(records, 0)
    frame?(nil)
    XCTAssertEqual(records, 1)
    LockScreenReadiness.deliver(error: nil, whenReady: { frame = $0 }) { _ in
      guard registered else { return }
      records += 1
    }
    registered = false
    frame?(nil)
    XCTAssertEqual(records, 1)
  }

  func testCancelledReadinessCannotOverwriteAnExplicitRendererFailure() {
    enum Failure: Error { case renderer }
    var records: [Error?] = []
    var frame: ((Error?) -> Void)?
    LockScreenReadiness.deliver(error: Failure.renderer, whenReady: { frame = $0 }) { records.append($0) }
    LockScreenReadiness.deliver(error: CancellationError(), whenReady: { frame = $0 }) { records.append($0) }
    LockScreenReadiness.deliver(error: nil, whenReady: { frame = $0 }) { records.append($0) }
    frame?(CancellationError())
    XCTAssertEqual(records.count, 1)
    XCTAssertTrue(records.first! is Failure)
  }

  func testInactiveSurfaceDefersItsLatestSourceUntilTheEnvironmentResumes() {
    let active = WallpaperPresentationAuthority.Request(role: .lockScreen, sessionLocked: true)
    var sleeping = active
    sleeping.displaysAsleep = true
    var offConsole = active
    offConsole.sessionOnConsole = false
    var suspended = active
    suspended.hostActivity = .suspended
    for inactive in [sleeping, offConsole, suspended] {
      XCTAssertFalse(WallpaperPresentationAuthority.mayPrepareReplacement(inactive, hasPendingAcquire: false))
      XCTAssertTrue(WallpaperPresentationAuthority.mayPrepareReplacement(inactive, hasPendingAcquire: true))
    }
    XCTAssertTrue(WallpaperPresentationAuthority.mayPrepareReplacement(active, hasPendingAcquire: false))
    var paused = active
    paused.userPaused = true
    XCTAssertTrue(WallpaperPresentationAuthority.mayPrepareReplacement(paused, hasPendingAcquire: false))
    XCTAssertFalse(WallpaperPresentationAuthority.mayPresent(paused))
    let unusedSaver = WallpaperPresentationAuthority.Request(
      role: .lockScreen, lockScreenEnabled: false, screenSaverEnabled: true)
    XCTAssertFalse(WallpaperPresentationAuthority.mayPrepareReplacement(unusedSaver, hasPendingAcquire: false))
    let desktop = WallpaperPresentationAuthority.Request(role: .lockScreen, presentedFor: .seconds(60))
    XCTAssertTrue(WallpaperPresentationAuthority.mayPrepareReplacement(desktop, hasPendingAcquire: false))
  }

  func testInactiveSourceChangesCauseNoReplacementAndResumeLoadsOnlyTheLatestSource() {
    func scene(_ name: String) -> LockScreenScene {
      LockScreenScene(
        displayID: 1, title: name, projectPath: name + "/project.json", assetsPath: name,
        fps: 30, scalingMode: 3, scalingFactor: 1, paused: false)
    }
    var current = scene("desktop")
    var desired = current
    var starts: [String] = []
    var request = WallpaperPresentationAuthority.Request(role: .lockScreen, sessionLocked: true)
    let replaceIfAllowed = {
      if !current.sharesRenderer(with: desired),
        WallpaperPresentationAuthority.mayPrepareReplacement(request, hasPendingAcquire: false)
      {
        current = desired
        starts.append(current.title)
      }
    }
    request.displaysAsleep = true
    desired = scene("lock")
    replaceIfAllowed()
    request.displaysAsleep = false
    request.sessionOnConsole = false
    desired = scene("another lock")
    replaceIfAllowed()
    request.sessionOnConsole = true
    request.hostActivity = .suspended
    desired = scene("saver")
    request.presentationMode = "idle"
    replaceIfAllowed()
    XCTAssertTrue(starts.isEmpty)
    XCTAssertEqual(current.title, "desktop")
    request.hostActivity = .active
    replaceIfAllowed()
    replaceIfAllowed()
    XCTAssertEqual(starts, ["saver"])
    XCTAssertEqual(current.title, "saver")
  }
}

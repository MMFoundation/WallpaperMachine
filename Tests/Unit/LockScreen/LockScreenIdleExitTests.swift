import XCTest

@testable import WallpaperMachine

@MainActor
final class LockScreenIdleExitTests: XCTestCase {
  private var busy = false
  private var exits = 0

  private func makeExit() -> LockScreenIdleExit {
    LockScreenIdleExit(
      grace: .milliseconds(50), isBusy: { [unowned self] in busy }, exit: { [unowned self] in exits += 1 })
  }

  private func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

  func testExitsOnlyAfterTheLastHostConnectionCloses() async throws {
    let idle = makeExit()
    idle.connectionOpened()
    idle.connectionOpened()
    idle.connectionClosed()
    try await settle()
    XCTAssertEqual(exits, 0)

    idle.connectionClosed()
    try await settle()
    XCTAssertEqual(exits, 1)
  }

  func testANewConnectionDuringTheGracePeriodKeepsTheProcess() async throws {
    let idle = makeExit()
    idle.connectionOpened()
    idle.connectionClosed()
    idle.connectionOpened()
    try await settle()
    XCTAssertEqual(exits, 0)
  }

  func testALiveSurfaceKeepsTheProcessUntilItIsRemoved() async throws {
    let idle = makeExit()
    busy = true
    idle.connectionOpened()
    idle.connectionClosed()
    try await settle()
    XCTAssertEqual(exits, 0)

    busy = false
    idle.surfacesChanged()
    try await settle()
    XCTAssertEqual(exits, 1)
  }

  func testASurfaceAcquiredDuringTheGracePeriodKeepsTheProcess() async throws {
    let idle = makeExit()
    idle.connectionOpened()
    idle.connectionClosed()
    busy = true
    try await settle()
    XCTAssertEqual(exits, 0)
  }
}

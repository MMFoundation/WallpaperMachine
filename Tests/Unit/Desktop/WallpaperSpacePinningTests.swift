import AppKit
import XCTest
@testable import WallpaperMachine

/// A wallpaper window that only records what is done to it, in one log shared with the mover.
@MainActor
private final class FakeWindow: WallpaperPinnableWindow {
    let number: Int
    var displayID: UInt32?
    var allSpaces = true
    var hidden = false
    var lastFade: TimeInterval?
    let log: Log
    var space: UInt64

    init(_ number: Int, display: UInt32, space: UInt64, log: Log) {
        self.number = number
        displayID = display
        self.space = space
        self.log = log
    }

    var joinsAllSpaces: Bool {
        get { allSpaces }
        set { allSpaces = newValue; log.events.append("\(number) all-spaces \(newValue)") }
    }

    func setConcealed(_ concealed: Bool, fade: TimeInterval) {
        hidden = concealed
        lastFade = fade
        log.events.append("\(number) \(concealed ? "hide" : "show")")
    }
}

@MainActor
private final class Log { var events: [String] = [] }

@MainActor
private final class FakeMover: WallpaperSpaceWindowMoving {
    var windows: [Int: FakeWindow] = [:]
    let log: Log
    init(log: Log) { self.log = log }

    func spaces(ofWindow number: Int) -> [UInt64]? { windows[number].map { [$0.space] } }

    func move(windows numbers: [Int], toSpace space: UInt64) {
        for number in numbers {
            windows[number]?.space = space
            log.events.append("\(number) move \(space)")
        }
    }
}

@MainActor
private final class PinRig {
    let log = Log()
    let mover: FakeMover
    var windows: [FakeWindow] = []
    var pins: [UInt32: WallpaperSpacePin] = [:]
    var holding = Set<UInt32>()
    var reduceMotion = false
    private(set) var clock = ContinuousClock.now
    private(set) var pinning: WallpaperSpacePinning!
    let center = NotificationCenter()

    init(available: Bool = true) {
        mover = FakeMover(log: log)
        pinning = WallpaperSpacePinning(
            windows: { [unowned self] in self.windows },
            pins: { [unowned self] in self.pins },
            holding: { [unowned self] in self.holding.contains($0) },
            mover: available ? mover : nil,
            reduceMotion: { [unowned self] in self.reduceMotion },
            now: { [unowned self] in self.clock },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
            center: center)
    }

    @discardableResult
    func window(_ number: Int, display: UInt32 = 1, space: UInt64 = 5) -> FakeWindow {
        let window = FakeWindow(number, display: display, space: space, log: log)
        windows.append(window)
        mover.windows[number] = window
        return window
    }

    func advance(_ duration: Duration) { clock = clock.advanced(by: duration) }
}

/// The pinning of wallpaper windows to a display's current desktop. Nothing here opens a window
/// or calls the window server.
@MainActor
final class WallpaperSpacePinningTests: XCTestCase {
    func testADisplayThatFollowsSpacesKeepsItsWindowsOnItsCurrentDesktopOnly() {
        let rig = PinRig()
        let pinned = rig.window(10, display: 1)
        let other = rig.window(20, display: 2)
        rig.pins = [1: .init(space: 5, content: .ready)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        XCTAssertFalse(pinned.allSpaces)
        XCTAssertEqual(pinned.space, 5)
        XCTAssertTrue(other.allSpaces, "a display that does not follow Spaces is left on every desktop")
        XCTAssertFalse(rig.log.events.contains { $0.hasPrefix("20") })

        rig.pins = [1: .init(space: 9, content: .ready)]
        rig.pinning.update()
        XCTAssertEqual(pinned.space, 9, "the window follows the person to the desktop they went to")
        XCTAssertFalse(pinned.hidden, "nothing changes there, so the wallpaper stays visible")

        rig.pins = [:]
        rig.pinning.update()
        XCTAssertTrue(pinned.allSpaces, "leaving the mode puts the window back on every desktop")
    }

    func testAWindowIsHiddenBeforeItMovesAndShownWithAFadeOnceItsWallpaperIsReady() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.pins = [1: .init(space: 5, content: .ready)]
        rig.pinning.start()
        defer { rig.pinning.stop() }
        rig.log.events.removeAll()

        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.update()

        XCTAssertEqual(rig.log.events, ["10 hide", "10 move 9"], "the old picture never reaches the new desktop")
        XCTAssertTrue(rig.pinning.isConcealed(1))

        rig.pins = [1: .init(space: 9, content: .ready)]
        rig.pinning.update()
        XCTAssertFalse(window.hidden)
        XCTAssertEqual(window.lastFade, WallpaperSpacePinning.Configuration().fade)
        XCTAssertFalse(rig.pinning.isConcealed(1))
    }

    func testReduceMotionShowsTheWindowWithoutAFade() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.reduceMotion = true
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        rig.pins = [1: .init(space: 9, content: .ready)]
        rig.pinning.update()

        XCTAssertFalse(window.hidden)
        XCTAssertEqual(window.lastFade, 0)
    }

    func testAHiddenDisplayWaitsForTheSwitchHoldToLetGo() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()
        defer { rig.pinning.stop() }
        rig.holding = [1]

        rig.pins = [1: .init(space: 9, content: .ready)]
        rig.pinning.update()
        XCTAssertTrue(window.hidden, "a web page or clip is not ready until the hold lets go")

        rig.holding = []
        rig.pinning.update()
        XCTAssertFalse(window.hidden)
    }

    func testASwitchHoldOnAVisibleDisplayHidesNothing() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.holding = [1]
        rig.pins = [1: .init(space: 5, content: .ready)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        XCTAssertFalse(window.hidden, "a manual switch keeps its veil on a visible window")
        XCTAssertFalse(rig.pinning.isConcealed(1))
    }

    func testALoadThatNeverEndsIsShownAfterTheCeilingButAWaitingOneStaysHidden() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()
        defer { rig.pinning.stop() }
        let ceiling = WallpaperSpacePinning.Configuration().loadingCeiling

        rig.advance(ceiling)
        rig.pinning.update()
        XCTAssertFalse(window.hidden, "a wallpaper that never loads does not leave the desktop on a still")

        rig.pinning.update()
        XCTAssertFalse(window.hidden, "and it is not hidden again until it is ready")

        rig.pins = [1: .init(space: 9, content: .ready)]
        rig.pinning.update()
        rig.pins = [1: .init(space: 5, content: .waiting)]
        rig.pinning.update()
        rig.advance(ceiling * 2)
        rig.pinning.update()
        XCTAssertTrue(window.hidden, "paused playback keeps the desktop's own still on screen")
    }

    func testAFullScreenSpaceLeavesTheWindowWhereItIs() {
        let rig = PinRig()
        let window = rig.window(10, space: 5)
        rig.pins = [1: .init(space: nil, content: .ready)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        XCTAssertFalse(window.allSpaces)
        XCTAssertEqual(window.space, 5)
        XCTAssertFalse(rig.log.events.contains { $0.contains("move") })
    }

    func testAWindowThatAppearsLaterIsPinnedAndHiddenLikeTheOthers() {
        let rig = PinRig()
        rig.window(10)
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        let late = rig.window(11, space: 5)
        rig.pinning.update()

        XCTAssertTrue(late.hidden)
        XCTAssertFalse(late.allSpaces)
        XCTAssertEqual(late.space, 9)
    }

    func testWithoutTheWindowServerCallsEveryWindowStaysOnEveryDesktop() {
        let rig = PinRig(available: false)
        let window = rig.window(10)
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        XCTAssertTrue(window.allSpaces)
        XCTAssertFalse(window.hidden)
        XCTAssertTrue(rig.log.events.isEmpty)
    }

    func testStopPutsEveryWindowBackOnEveryDesktopAndShowsIt() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.pins = [1: .init(space: 9, content: .loading)]
        rig.pinning.start()

        rig.pinning.stop()

        XCTAssertTrue(window.allSpaces)
        XCTAssertFalse(window.hidden)
        XCTAssertFalse(rig.pinning.isConcealed(1))
    }

    func testADesktopChangeAnnouncedByTheSpaceMonitorUpdatesThePins() {
        let rig = PinRig()
        let window = rig.window(10)
        rig.pins = [1: .init(space: 5, content: .ready)]
        rig.pinning.start()
        defer { rig.pinning.stop() }

        rig.pins = [1: .init(space: 9, content: .ready)]
        rig.center.post(name: WallpaperSpaceMonitor.didChangeNotification, object: nil)

        XCTAssertEqual(window.space, 9)
    }
}

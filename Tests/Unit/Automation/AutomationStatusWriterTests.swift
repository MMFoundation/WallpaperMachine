import XCTest
@testable import WallpaperMachine

/// Event-driven atomic writes to `status.json`, isolated under a temporary `WALLPAPER_MACHINE_HOME`.
@MainActor
final class AutomationStatusWriterTests: XCTestCase {
    private var root: URL!
    private var previousHome: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-status-\(UUID().uuidString)", isDirectory: true)
        setenv("WALLPAPER_MACHINE_HOME", root.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousHome {
            setenv("WALLPAPER_MACHINE_HOME", previousHome, 1)
        } else {
            unsetenv("WALLPAPER_MACHINE_HOME")
        }
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testStatusFileLivesUnderWallpaperMachineHomeAndWritesOnlyOnChange() async throws {
        XCTAssertEqual(ClientPaths.automationStatusURL.deletingLastPathComponent().path, root.path)
        XCTAssertEqual(ClientPaths.automationStatusURL.lastPathComponent, "status.json")

        var currentDate = Date(timeIntervalSince1970: 1_700_000_000)
        var diskWrites = 0
        let writer = AutomationStatusWriter(
            fileURL: ClientPaths.automationStatusURL,
            now: { currentDate },
            writeAtomically: { data, url in
                diskWrites += 1
                try data.write(to: url, options: .atomic)
            })

        let initial = AutomationStatusWriter.State(
            isPlaying: true,
            isPaused: false,
            isMuted: false,
            isPresentationMode: false,
            desktopWidgetsHidden: false,
            displays: [
                .init(
                    displayID: "primary",
                    displayTitle: "Built-in Retina Display",
                    wallpaperID: "aurora",
                    wallpaperTitle: "Aurora",
                    wallpaperKind: "scene",
                    isFavorite: true),
            ])

        XCTAssertTrue(writer.update(initial))
        await writer.flush()
        XCTAssertEqual(writer.writeCount, 1)
        XCTAssertEqual(diskWrites, 1)

        // Repeated identical state does NOT touch disk even as wall-clock time advances.
        currentDate = currentDate.addingTimeInterval(60)
        XCTAssertFalse(writer.update(initial))
        await writer.flush()
        XCTAssertEqual(writer.writeCount, 1)
        XCTAssertEqual(diskWrites, 1)

        let firstData = try Data(contentsOf: ClientPaths.automationStatusURL)
        let firstSnapshot = try JSONDecoder().decode(AutomationStatusWriter.Snapshot.self, from: firstData)
        XCTAssertEqual(firstSnapshot.schemaVersion, 1)
        XCTAssertTrue(firstSnapshot.isPlaying)
        XCTAssertFalse(firstSnapshot.isPaused)
        XCTAssertFalse(firstSnapshot.isMuted)
        XCTAssertFalse(firstSnapshot.isPresentationMode)
        XCTAssertEqual(firstSnapshot.displays.map(\.wallpaperID), ["aurora"])

        // Entering presentation mode writes a fresh atomic snapshot.
        var presented = initial
        presented.isPlaying = false
        presented.isPaused = true
        presented.isMuted = true
        presented.isPresentationMode = true
        presented.desktopWidgetsHidden = true
        XCTAssertTrue(writer.update(presented))
        await writer.flush()
        XCTAssertEqual(writer.writeCount, 2)
        XCTAssertEqual(diskWrites, 2)

        let secondData = try Data(contentsOf: ClientPaths.automationStatusURL)
        let secondSnapshot = try JSONDecoder().decode(AutomationStatusWriter.Snapshot.self, from: secondData)
        XCTAssertTrue(secondSnapshot.isPaused)
        XCTAssertTrue(secondSnapshot.isMuted)
        XCTAssertTrue(secondSnapshot.isPresentationMode)
        XCTAssertTrue(secondSnapshot.desktopWidgetsHidden)
        XCTAssertNotEqual(secondSnapshot.updatedAt, firstSnapshot.updatedAt)
    }
}

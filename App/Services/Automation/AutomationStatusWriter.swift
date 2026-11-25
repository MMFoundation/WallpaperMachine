import Foundation

/// Event-driven atomic writer for the read-only `status.json` snapshot read by external tools
/// such as Raycast, SketchyBar, or Stream Deck.
///
/// Writes happen ONLY when the observed playback, mute, presentation-mode, desktop-widget, or
/// active-wallpaper state actually changes. Zero timers, zero polling, and zero open sockets.
@MainActor
final class AutomationStatusWriter {
    struct DisplayStatus: Codable, Equatable, Sendable {
        var displayID: String
        var displayTitle: String
        var wallpaperID: String?
        var wallpaperTitle: String?
        var wallpaperKind: String?
        var isFavorite: Bool
    }

    /// Comparable state payload; identical consecutive updates perform no disk write.
    struct State: Equatable, Sendable {
        var isPlaying: Bool
        var isPaused: Bool
        var isMuted: Bool
        var isPresentationMode: Bool
        var desktopWidgetsHidden: Bool
        var displays: [DisplayStatus]
    }

    /// On-disk JSON envelope written atomically to `status.json`.
    struct Snapshot: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var isPlaying: Bool
        var isPaused: Bool
        var isMuted: Bool
        var isPresentationMode: Bool
        var desktopWidgetsHidden: Bool
        var displays: [DisplayStatus]
        var updatedAt: String
    }

    private actor DiskSink {
        private let fileURL: URL
        private let writeAtomically: @Sendable (Data, URL) throws -> Void

        init(
            fileURL: URL,
            writeAtomically: @escaping @Sendable (Data, URL) throws -> Void
        ) {
            self.fileURL = fileURL
            self.writeAtomically = writeAtomically
        }

        func write(_ data: Data) {
            do {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try writeAtomically(data, fileURL)
            } catch {
                AppLog.warn("automation status: could not write \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    let fileURL: URL
    private let sink: DiskSink
    private let now: @MainActor () -> Date
    private var lastState: State?
    private var pendingTask: Task<Void, Never>?
    private(set) var writeCount = 0

    init(
        fileURL: URL = ClientPaths.automationStatusURL,
        now: @escaping @MainActor () -> Date = Date.init,
        writeAtomically: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.sink = DiskSink(fileURL: fileURL, writeAtomically: writeAtomically)
    }

    /// Publishes `state` to disk if and only if it differs from the last published state.
    /// Returns true when a write was scheduled, false when skipped as unchanged.
    @discardableResult
    func update(_ state: State) -> Bool {
        guard state != lastState else { return false }
        lastState = state
        writeCount += 1

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let snapshot = Snapshot(
            schemaVersion: 1,
            isPlaying: state.isPlaying,
            isPaused: state.isPaused,
            isMuted: state.isMuted,
            isPresentationMode: state.isPresentationMode,
            desktopWidgetsHidden: state.desktopWidgetsHidden,
            displays: state.displays,
            updatedAt: formatter.string(from: now()))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return false }

        let previous = pendingTask
        let sink = self.sink
        pendingTask = Task(priority: .utility) {
            await previous?.value
            await sink.write(data)
        }
        return true
    }

    /// Waits for any queued atomic write to finish (for deterministic tests and clean shutdown).
    func flush() async {
        await pendingTask?.value
    }
}

import CoreMedia
import Foundation
import Observation

/// A validated A–B loop trim interval for a video wallpaper, measured in seconds from the start of
/// the clip (`0 <= startSeconds < endSeconds`, with `endSeconds - startSeconds >= 0.5`).
///
/// Stored per wallpaper and clamped at playback time against the actual video track's duration so
/// replacing a clip with a shorter file falls back cleanly without stalling or crashing.
struct VideoTrimRange: Codable, Equatable, Hashable, Sendable {
    /// Shortest allowed loop interval, in seconds.
    static let minimumDuration: Double = 0.5
    /// Floating-point slack for decimal steps such as `1.2 - 0.7 = 0.4999999999999999`.
    private static let durationTolerance: Double = 1e-9

    let startSeconds: Double
    let endSeconds: Double

    /// Duration of one loop pass, in seconds.
    var duration: Double { endSeconds - startSeconds }

    /// The same interval as a `ClosedRange<Double>`, for `WebMPlayer` / `WebMFeeder`.
    var closedRange: ClosedRange<Double> { startSeconds...endSeconds }

    enum Failure: LocalizedError, Equatable {
        case invalidRange
        case invalidIdentity

        var errorDescription: String? {
            switch self {
            case .invalidRange:
                String(localized: "Video loop trim must start at or after 0 seconds and last at least 0.5 seconds.")
            case .invalidIdentity:
                String(localized: "Choose an installed video wallpaper.")
            }
        }
    }

    init(startSeconds: Double, endSeconds: Double) throws {
        guard startSeconds.isFinite, endSeconds.isFinite,
              startSeconds >= 0, endSeconds > startSeconds,
              (endSeconds - startSeconds) + Self.durationTolerance >= Self.minimumDuration
        else { throw Failure.invalidRange }
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            startSeconds: values.decode(Double.self, forKey: .startSeconds),
            endSeconds: values.decode(Double.self, forKey: .endSeconds))
    }

    /// Clamps this trim range against an asset's actual duration in seconds.
    ///
    /// Returns `nil` when the asset is shorter than `minimumDuration`, or when the saved interval
    /// has less than `minimumDuration` of overlap with `[0, assetDuration]`, so playback falls back
    /// cleanly to the full clip.
    func clamped(toAssetDuration assetDuration: Double) -> VideoTrimRange? {
        guard assetDuration.isFinite,
              assetDuration + Self.durationTolerance >= Self.minimumDuration,
              startSeconds < assetDuration, endSeconds > 0
        else { return nil }
        let clampedStart = max(0, startSeconds)
        let clampedEnd = min(assetDuration, endSeconds)
        guard (clampedEnd - clampedStart) + Self.durationTolerance >= Self.minimumDuration else {
            return nil
        }
        return try? VideoTrimRange(startSeconds: clampedStart, endSeconds: clampedEnd)
    }

    /// Clamps this trim range into a video track's `CMTimeRange` for `AVPlayerLooper`.
    ///
    /// Preserves non-zero track start offsets and falls back to `trackRange` when the trim range
    /// does not leave at least `minimumDuration` inside the track.
    func timeRange(clampedTo trackRange: CMTimeRange) -> CMTimeRange {
        guard trackRange.isValid, trackRange.start.isNumeric, trackRange.duration.isNumeric,
              trackRange.duration > .zero
        else { return .invalid }
        let trackDuration = trackRange.duration.seconds
        guard let clamped = clamped(toAssetDuration: trackDuration) else { return trackRange }
        let timescale: CMTimeScale = trackRange.duration.timescale > 0
            ? max(trackRange.duration.timescale, 600)
            : 600
        let startOffset = CMTime(seconds: clamped.startSeconds, preferredTimescale: timescale)
        let start = CMTimeAdd(trackRange.start, startOffset)
        let trackEnd = CMTimeRangeGetEnd(trackRange)
        let requestedDuration = CMTime(seconds: clamped.duration, preferredTimescale: timescale)
        let availableDuration = CMTimeSubtract(trackEnd, start)
        let clampedDuration = CMTimeMinimum(requestedDuration, availableDuration)
        guard clampedDuration.isNumeric,
              clampedDuration.seconds + Self.durationTolerance >= Self.minimumDuration
        else { return trackRange }
        return CMTimeRange(start: start, duration: clampedDuration)
    }

    /// The `CMTimeRange` an `AVPlayerLooper` should play for `trackRange` and optional `trim`.
    static func effectiveLoopRange(trackRange: CMTimeRange, trim: VideoTrimRange?) -> CMTimeRange {
        guard let trim else { return trackRange }
        return trim.timeRange(clampedTo: trackRange)
    }

    /// Formats a timestamp in seconds as `MM:SS.t` (for example `01:23.4`), using ASCII digits so
    /// monospaced Inspector readouts stay fixed-width across locales.
    static func formatTimestamp(_ seconds: Double) -> String {
        let clamped = seconds.isFinite && seconds > 0 ? seconds : 0
        let totalTenths = Int((clamped * 10).rounded())
        let tenths = totalTenths % 10
        let totalSeconds = totalTenths / 10
        let secs = totalSeconds % 60
        let mins = totalSeconds / 60
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }

    /// Parses `MM:SS.t`, `M:SS`, `HH:MM:SS.t`, or plain seconds into a non-negative number of
    /// seconds, or `nil` when malformed.
    static func parseTimestamp(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let seconds = Double(parts[0]), seconds.isFinite, seconds >= 0 else { return nil }
            return seconds
        case 2:
            guard let mins = Int(parts[0]), mins >= 0,
                  let secs = Double(parts[1]), secs.isFinite, secs >= 0, secs < 60
            else { return nil }
            return Double(mins) * 60 + secs
        case 3:
            guard let hours = Int(parts[0]), hours >= 0,
                  let mins = Int(parts[1]), (0..<60).contains(mins),
                  let secs = Double(parts[2]), secs.isFinite, secs >= 0, secs < 60
            else { return nil }
            return Double(hours) * 3600 + Double(mins) * 60 + secs
        default:
            return nil
        }
    }
}

/// Stores per-wallpaper A–B video loop trim ranges in `UserDefaults`.
///
/// Observable directly by SwiftUI views (`@Observable`) and also posts `didChangeNotification` so
/// `NativeVideoWallpaperHost` applies live updates to running AVFoundation and WebM surfaces
/// without polling or restarting decoders unnecessarily.
@MainActor
@Observable
final class VideoTrimStore {
    static let shared = VideoTrimStore()
    nonisolated static let storageKey = "WallpaperMachine.videoTrimRanges"
    static let didChangeNotification = Notification.Name("WallpaperMachine.videoTrimRangesDidChange")
    nonisolated static let wallpaperIDUserInfoKey = "wallpaperID"

    private struct Envelope: Codable, Equatable {
        var version = 1
        var ranges: [String: VideoTrimRange] = [:]
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var envelope: Envelope
    /// Bumped on every persisted mutation so SwiftUI views re-read `trimRange(for:)`.
    private(set) var changes: UInt64 = 0

    init(defaults: UserDefaults = ClientPreferences.defaults) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Envelope.self, from: $0) }
        envelope = saved?.version == 1 ? saved! : Envelope()
    }

    func trimRange(for wallpaperID: String) -> VideoTrimRange? {
        _ = changes
        return envelope.ranges[wallpaperID]
    }

    func allRanges() -> [String: VideoTrimRange] {
        _ = changes
        return envelope.ranges
    }

    func set(_ range: VideoTrimRange, for wallpaperID: String) throws {
        guard Self.validIdentity(wallpaperID) else { throw VideoTrimRange.Failure.invalidIdentity }
        guard envelope.ranges[wallpaperID] != range else { return }
        var changed = envelope
        changed.ranges[wallpaperID] = range
        try persist(changed, wallpaperID: wallpaperID)
    }

    func clear(for wallpaperID: String) throws {
        guard Self.validIdentity(wallpaperID) else { throw VideoTrimRange.Failure.invalidIdentity }
        guard envelope.ranges[wallpaperID] != nil else { return }
        var changed = envelope
        changed.ranges[wallpaperID] = nil
        try persist(changed, wallpaperID: wallpaperID)
    }

    func forget(_ ids: Set<String>) throws {
        var changed = envelope
        for id in ids { changed.ranges[id] = nil }
        guard changed.ranges != envelope.ranges else { return }
        try persist(changed, wallpaperID: nil)
    }

    /// Validates a backup payload before restoring it into `UserDefaults`
    /// (`WallpaperBackupPreferences.validate(_:forKey:)`).
    nonisolated static func validateArchiveData(_ data: Data) throws {
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        guard decoded.version == 1 else {
            throw WallpaperBackupFailure(
                message: String(localized: "The backup contains an invalid preference value."))
        }
        for wallpaperID in decoded.ranges.keys {
            guard validIdentity(wallpaperID) else {
                throw WallpaperBackupFailure(
                    message: String(localized: "The backup contains an invalid preference value."))
            }
        }
    }

    nonisolated static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.contains("/") && !value.contains("\\")
            && value != "." && value != ".." && !value.unicodeScalars.contains { $0.value < 32 }
    }

    private func persist(_ changed: Envelope, wallpaperID: String?) throws {
        let data = try JSONEncoder().encode(changed)
        defaults.set(data, forKey: Self.storageKey)
        envelope = changed
        changes &+= 1
        var userInfo: [String: String] = [:]
        if let wallpaperID { userInfo[Self.wallpaperIDUserInfoKey] = wallpaperID }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: userInfo)
    }
}

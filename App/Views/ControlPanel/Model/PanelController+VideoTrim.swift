import AVFoundation
import Foundation

/// Cached metadata-only duration read for one video wallpaper at one library revision.
struct VideoTrimDurationEntry: Equatable, Sendable {
  enum Outcome: Equatable, Sendable {
    case loading
    case duration(Double)
    case unavailable
  }

  let revision: UInt64
  let outcome: Outcome
}

/// Pure view model snapshot for the Installed inspector's Loop trim card (video wallpapers only).
struct VideoTrimState: Equatable {
  let wallpaperID: String
  let displayID: String
  let durationSeconds: Double?
  let isLoadingDuration: Bool
  let durationFailed: Bool
  let savedRange: VideoTrimRange?

  var effectiveRange: VideoTrimRange? {
    guard let savedRange else { return nil }
    guard let durationSeconds else { return savedRange }
    return savedRange.clamped(toAssetDuration: durationSeconds)
  }

  var effectiveStart: Double { effectiveRange?.startSeconds ?? 0 }

  var effectiveEnd: Double {
    if let effectiveRange { return effectiveRange.endSeconds }
    return durationSeconds ?? 0
  }

  var loopDuration: Double { max(0, effectiveEnd - effectiveStart) }

  var isTrimmed: Bool { savedRange != nil }

  var canTrim: Bool {
    guard let durationSeconds else { return false }
    return durationSeconds >= VideoTrimRange.minimumDuration
  }

  var isTooShort: Bool {
    guard let durationSeconds else { return false }
    return durationSeconds < VideoTrimRange.minimumDuration
  }
}

@MainActor
private final class VideoTrimDurationTaskRef {
  var task: Task<Void, Never>?
}

extension PanelController {
  /// Derived Loop trim state for the selected installed video wallpaper, or `nil` for non-video
  /// wallpapers. Performs zero disk or decoder work in the getter.
  var videoTrimState: VideoTrimState? {
    _ = videoTrim.changes
    guard let id = store.appSnapshot.selectedWallpaperId,
          let entry = store.librarySnapshot.wallpapers.first(where: { $0.id == id }),
          entry.kind == .video
    else { return nil }
    let displayID = navigation.targetDisplayID
    let revision = store.libraryRefreshRevision
    let cached = videoTrimDurations[id].flatMap { $0.revision == revision ? $0.outcome : nil }
    let durationSeconds: Double?
    let isLoading: Bool
    let failed: Bool
    switch cached {
    case .loading:
      durationSeconds = nil
      isLoading = true
      failed = false
    case let .duration(seconds):
      durationSeconds = seconds
      isLoading = false
      failed = false
    case .unavailable:
      durationSeconds = nil
      isLoading = false
      failed = true
    case nil:
      durationSeconds = nil
      isLoading = false
      failed = false
    }
    return VideoTrimState(
      wallpaperID: id,
      displayID: displayID,
      durationSeconds: durationSeconds,
      isLoadingDuration: isLoading,
      durationFailed: failed,
      savedRange: videoTrim.trimRange(for: id))
  }

  /// Reads the selected video wallpaper's container duration off the main thread without decoding
  /// video frames, caching the result for the current library revision.
  func loadVideoTrimDuration(for wallpaperID: String, display displayID: String) async {
    guard !isStopped else { return }
    let revision = store.libraryRefreshRevision
    if let cached = videoTrimDurations[wallpaperID], cached.revision == revision {
      switch cached.outcome {
      case .duration, .loading:
        return
      case .unavailable:
        break
      }
    }
    videoTrimDurationTasks[wallpaperID]?.cancel()
    videoTrimDurations[wallpaperID] = VideoTrimDurationEntry(revision: revision, outcome: .loading)

    let taskRef = VideoTrimDurationTaskRef()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if let current = taskRef.task, self.videoTrimDurationTasks[wallpaperID] == current {
          self.videoTrimDurationTasks.removeValue(forKey: wallpaperID)
        }
      }
      let seconds: Double?
      do {
        if let reader = self.videoTrimDurationReader {
          seconds = try await reader(wallpaperID, displayID)
        } else {
          let request = try await self.store.wallpaperPreviewRequestAsync(id: wallpaperID, displayID: displayID)
          let validated = try await WallpaperPreviewLoader().validate(request)
          if validated.kind == .video {
            let fileURL = validated.projectURL.appendingPathComponent(validated.entryFile)
            seconds = await Self.readVideoDurationSeconds(at: fileURL)
          } else {
            seconds = nil
          }
        }
      } catch is CancellationError {
        if let current = taskRef.task,
           self.videoTrimDurationTasks[wallpaperID] == current,
           self.videoTrimDurations[wallpaperID] == VideoTrimDurationEntry(revision: revision, outcome: .loading)
        {
          self.videoTrimDurations.removeValue(forKey: wallpaperID)
        }
        return
      } catch {
        seconds = nil
      }
      guard !Task.isCancelled, !self.isStopped else { return }
      guard self.store.libraryRefreshRevision == revision else { return }
      if let seconds, seconds.isFinite, seconds > 0 {
        self.videoTrimDurations[wallpaperID] = VideoTrimDurationEntry(
          revision: revision, outcome: .duration(seconds))
      } else {
        self.videoTrimDurations[wallpaperID] = VideoTrimDurationEntry(
          revision: revision, outcome: .unavailable)
      }
    }
    taskRef.task = task
    videoTrimDurationTasks[wallpaperID] = task
    await task.value
  }

  /// Persists a validated A–B loop trim range for an installed video wallpaper. Running native
  /// video players (`NativeVideoWallpaperHost`) observe `VideoTrimStore` and apply it live.
  func setVideoTrim(_ wallpaperID: String, startSeconds: Double, endSeconds: Double) async throws {
    try await run(.immediate) {
      let id = try installedWallpaperID(wallpaperID)
      let range = try VideoTrimRange(startSeconds: startSeconds, endSeconds: endSeconds)
      try videoTrim.set(range, for: id)
    }
  }

  /// Clears any saved A–B loop trim range for an installed video wallpaper so the full clip loops.
  func resetVideoTrim(_ wallpaperID: String) async throws {
    try await run(.immediate) {
      let id = try installedWallpaperID(wallpaperID)
      try videoTrim.clear(for: id)
    }
  }

  /// Metadata-only duration read supporting both AVFoundation containers and Matroska/WebM.
  nonisolated static func readVideoDurationSeconds(at url: URL) async -> Double? {
    if VideoFormatSupport.isMatroska(url) {
      return await Task.detached(priority: .utility) {
        guard case let .success(file) = WebMOpening.open(url: url),
              file.duration.isNumeric, file.duration > .zero
        else { return nil }
        let seconds = file.duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
      }.value
    }
    let asset = AVURLAsset(url: url)
    if let video = try? await asset.loadTracks(withMediaType: .video).first,
       let range = try? await video.load(.timeRange),
       range.isValid, range.duration.isNumeric, range.duration > .zero
    {
      let seconds = range.duration.seconds
      if seconds.isFinite, seconds > 0 { return seconds }
    }
    if let duration = try? await asset.load(.duration),
       duration.isNumeric, duration > .zero
    {
      let seconds = duration.seconds
      if seconds.isFinite, seconds > 0 { return seconds }
    }
    return nil
  }
}

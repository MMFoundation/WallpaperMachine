import Foundation

/// Which path draws a plain video wallpaper on the lock screen and as the screen saver.
enum LockScreenVideoPath: Equatable {
  /// The scene engine, which plays every video it is given. `reason` says why the native
  /// player was not used, and is nil when the configuration never asked for it.
  case sceneEngine(reason: String?)
  /// An AVFoundation layer with hardware decode.
  case avFoundation(URL)

  var isNative: Bool {
    if case .avFoundation = self { return true }
    return false
  }
}

/// The decision, kept apart from the player so it can be exercised without a lock screen.
///
/// It mirrors the app: the native player takes a clip only when the Video backend setting
/// selects it (the app publishes `nativeVideoFile` then and only then), and only when
/// `NativeVideoAdmission` accepts the clip, the same rule the desktop applies. The clip plays at
/// its own frame rate. A clip AVFoundation cannot open, such as WebM, goes to the scene engine.
enum LockScreenVideoPlanner {
  /// The scene's media file in the exchange directory, as a path relative to it. Nil when the
  /// scene does not ask for the native player, or names a file that cannot lie inside its
  /// project folder.
  static func mediaPath(of scene: LockScreenScene) -> String? {
    guard scene.webEntryFile == nil, let file = scene.nativeVideoFile, !file.isEmpty,
      !file.hasPrefix("/")
    else { return nil }
    let parts = file.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.contains(".."), !parts.contains("."), !parts.contains("") else { return nil }
    let project = scene.projectPath.split(separator: "/", omittingEmptySubsequences: false)
    guard project.count >= 2 else { return nil }
    return (project.dropLast() + parts).joined(separator: "/")
  }

  /// `resolve` turns the relative path into a readable file and throws when it cannot (the
  /// extension's own sandboxed asset lookup); `admission` is the desktop's rule.
  static func decide(
    scene: LockScreenScene, enabled: Bool = true,
    resolve: (String) throws -> URL,
    admission: (URL) async -> NativeVideoRefusal? = { url in
      await NativeVideoAdmission.evaluate(url: url)
    }
  ) async -> LockScreenVideoPath {
    guard scene.webEntryFile == nil, scene.nativeVideoFile != nil else {
      return .sceneEngine(reason: nil)
    }
    guard enabled else { return .sceneEngine(reason: "the native player failed on this clip earlier") }
    guard let path = mediaPath(of: scene) else {
      return .sceneEngine(reason: "the clip's path is not inside its project")
    }
    let url: URL
    do { url = try resolve(path) } catch {
      return .sceneEngine(reason: "the clip is unavailable: \(error.localizedDescription)")
    }
    if let refusal = await admission(url) {
      return .sceneEngine(reason: refusal.reason)
    }
    return .avFoundation(url)
  }
}

/// The clip the native player failed on, so that failure is held against that file and not
/// against the surface. The app publishes every revision of a wallpaper under its own folder, so
/// a replaced or different video has a different identity and tries the native player again,
/// while the same clip never retries it: its replacement draws it with the scene engine.
struct LockScreenNativeVideoMemory: Equatable {
  private(set) var failedClip: String?

  /// Whether the native player may be tried for `scene`'s clip.
  func allows(_ scene: LockScreenScene) -> Bool {
    guard let clip = LockScreenVideoPlanner.mediaPath(of: scene) else { return true }
    return clip != failedClip
  }

  mutating func recordFailure(of scene: LockScreenScene) {
    failedClip = LockScreenVideoPlanner.mediaPath(of: scene)
  }
}

/// A bound on work that may never finish, with the clock as a parameter so a test does not wait.
enum LockScreenDeadline {
  struct Expired: Error, LocalizedError, Equatable {
    let timeout: Duration
    var errorDescription: String? { "it did not finish within \(timeout)" }
  }

  /// How long the native player has, from the decision to the first frame, before the surface
  /// gives the clip to the scene engine. It is well inside the surface's 30 second first-frame
  /// deadline, because the scene engine gets that whole deadline of its own after it.
  static let nativeAttempt = Duration.seconds(10)

  /// `operation`'s result, or `Expired` once `sleep(timeout)` returns first. The loser is
  /// cancelled; an `operation` that ignores cancellation is abandoned, not waited for.
  @MainActor
  static func run<T>(
    within timeout: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    operation: @escaping @MainActor () async throws -> T
  ) async throws -> T {
    let race = Race()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let work = Task { @MainActor in
          let result: Result<T, Error>
          do { result = .success(try await operation()) } catch { result = .failure(error) }
          guard race.settle() else { return }
          race.timer?.cancel()
          continuation.resume(with: result)
        }
        race.work = work
        race.timer = Task { @MainActor in
          do { try await sleep(timeout) } catch { return }
          guard race.settle() else { return }
          work.cancel()
          continuation.resume(throwing: Expired(timeout: timeout))
        }
      }
    } onCancel: {
      // The operation is told, and ends by itself; the timer stays the bound if it does not.
      race.work?.cancel()
    }
  }

  /// Which of the operation and the timer finished first, shared with the cancellation handler.
  private final class Race: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var _work: Task<Void, Never>?
    private var _timer: Task<Void, Never>?
    var work: Task<Void, Never>? {
      get { lock.withLock { _work } }
      set { lock.withLock { _work = newValue } }
    }
    var timer: Task<Void, Never>? {
      get { lock.withLock { _timer } }
      set { lock.withLock { _timer = newValue } }
    }
    func settle() -> Bool {
      lock.withLock {
        guard !settled else { return false }
        settled = true
        return true
      }
    }
  }
}

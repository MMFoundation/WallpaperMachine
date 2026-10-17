import Foundation

/// The app publishes a complete immutable asset revision before replacing this file.
/// The extension never reads draft options or the app's private configuration files.
struct LockScreenConfiguration: Codable, Equatable {
  static let extensionIdentifier = "app.wallpapermachine.wallpaper-extension"
  static let changedNotification = "app.wallpapermachine.lock-screen.changed"
  static let fileName = "configuration.json"
  static let supportedVersion = 2
  /// Home-relative exchange directory. The app publishes here and the extension
  /// reads here and writes readiness and its log back. It lies outside both
  /// sandbox containers because macOS asks "would like to access data from other
  /// apps" on every launch when the app touches the extension's container.
  /// `Extension/WallpaperExtension.entitlements` must grant the same path.
  static let exchangeRelativePath = "Library/Application Support/WallpaperMachine/LockScreenExchange"
  /// Resolved against the account's real home: inside the sandbox `NSHomeDirectory()`
  /// names the container, and both processes must agree on one directory.
  static let exchangeDirectory: URL = {
    let home: URL
    if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
      home = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    } else {
      home = FileManager.default.homeDirectoryForCurrentUser
    }
    return home.appendingPathComponent(exchangeRelativePath, isDirectory: true)
  }()
  /// The private `com.apple.wallpaper` protocol the extension speaks has only been
  /// verified on macOS 26 and later; earlier releases keep the feature off.
  static var isSupportedBySystem: Bool {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
  }

  var version: Int = supportedVersion
  var revision: String = UUID().uuidString
  var scenes: [LockScreenScene]
  var lockScreenEnabled: Bool = true
  var screenSaverEnabled: Bool = false
}

struct LockScreenScene: Codable, Equatable {
  var displayID: UInt32
  var title: String
  /// Paths relative to the exchange directory, never external URLs.
  var projectPath: String
  var assetsPath: String
  var previewPath: String?
  var fps: UInt32
  /// Native renderer values: none=0, stretch=1, fit=2, fill=3.
  var scalingMode: Int32
  var scalingFactor: Double
  var propertiesJSON: String?
  var paused: Bool
  /// A project-relative HTML entry; nil selects the scene/video renderer.
  var webEntryFile: String? = nil
  /// Where the picture sits in the room its display leaves around it. Absent from a
  /// configuration an older app wrote and for a web page, which fills its window; both
  /// read as centred, and a copy of the extension that predates the key ignores it.
  var framing: LockScreenFraming? = nil
  /// The app's Scene renderer setting for this scene. Absent from a configuration an
  /// older app wrote and for a web page, which has no scene renderer; absent reads as
  /// `LockScreenSceneRenderer.default`, the app's own default, and a copy of the
  /// extension that predates the key ignores it.
  var sceneRenderer: LockScreenSceneRenderer? = nil
  /// The media file of a plain video wallpaper, relative to its project folder, present for
  /// every plain video the app can find the file of: the extension plays it through an
  /// AVFoundation layer when AVFoundation can open it, through the WebM player for a WebM or
  /// Matroska file, and otherwise, like every scene that lacks the key, through the scene engine. Absent from a configuration an older
  /// app wrote and for scenes and web pages; a copy of the extension that predates the key
  /// ignores it.
  var nativeVideoFile: String? = nil

  var effectiveFraming: LockScreenFraming { framing ?? .centered }
  var effectiveSceneRenderer: LockScreenSceneRenderer { sceneRenderer ?? .default }

  /// Whether a surface already showing `other` can take this scene without a new
  /// renderer. Frame rate, title and pause apply to the running renderer, and the
  /// preview path is not read by it. The scaling and the position are, like the
  /// project, only read when the renderer is built, so a change of either replaces it.
  /// So is the scene renderer, which the engine reads once, when the scene is parsed, and the
  /// choice of the native video player and the file it plays.
  func sharesRenderer(with other: LockScreenScene) -> Bool {
    projectPath == other.projectPath && assetsPath == other.assetsPath
      && webEntryFile == other.webEntryFile && propertiesJSON == other.propertiesJSON
      && scalingMode == other.scalingMode && scalingFactor == other.scalingFactor
      && effectiveFraming == other.effectiveFraming
      && effectiveSceneRenderer == other.effectiveSceneRenderer
      && nativeVideoFile == other.nativeVideoFile
  }
}

/// Which renderer draws a scene, by the names the app's Scene renderer setting and the
/// engine use. A preference, not an outcome: a scene the native backend cannot draw as a
/// whole is drawn by Compatibility, and the extension logs which one drew. With
/// `nativeMetalOnly` there is no Compatibility to fall to, and the scene is held instead.
enum LockScreenSceneRenderer: String, Codable, Equatable {
  case compatibility
  case nativeMetalPreferred = "native_metal_preferred"
  /// Native Metal and nothing else: a scene it cannot draw is held, on its last frame or its preview
  /// picture, and reported as a failure (`LockScreenHeldFailure`) instead of being drawn by Compatibility.
  case nativeMetalOnly = "native_metal_only"

  /// What the app's setting defaults to, and so what a configuration without the key means.
  static let `default` = LockScreenSceneRenderer.nativeMetalPreferred

  /// The value of `owe_scene_renderer_preference`.
  var enginePreference: Int32 {
    switch self {
    case .compatibility: 0
    case .nativeMetalPreferred: 1
    case .nativeMetalOnly: 2
    }
  }

  /// A name this build does not know, written by a newer app, reads as the default
  /// rather than making the whole configuration unreadable: the default is itself only
  /// a preference, so the worst outcome is Compatibility for a scene Metal cannot draw.
  init(from decoder: Decoder) throws {
    let name = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: name) ?? .default
  }
}

extension LockScreenConfiguration {
  /// The renderer every scene of this configuration shares: the engine's preference is
  /// process-wide, and the app writes one value for all of them. A configuration without
  /// scenes has none.
  var sceneRenderer: LockScreenSceneRenderer? {
    scenes.first(where: { $0.webEntryFile == nil })?.effectiveSceneRenderer
  }
}

/// A position as fractions of the room around the picture on each axis: 0 is the left
/// or top edge, 1 the right or bottom edge and 0.5 on both the centred layout every
/// wallpaper has until it is moved. The renderer clamps what it is given, so
/// `isValid` is what keeps a hand-edited or corrupt file from being drawn silently
/// somewhere else.
struct LockScreenFraming: Codable, Equatable {
  static let centered = LockScreenFraming(panX: 0.5, panY: 0.5)

  var panX: Double = 0.5
  var panY: Double = 0.5

  var isValid: Bool {
    (0.0...1.0).contains(panX) && (0.0...1.0).contains(panY)
  }
}

/// Written once a non-preview surface has GPU-ready pixels, or with `error` when
/// acquiring or replacing its renderer failed; never optimistically.
///
/// `held` is the other way a surface can be ready without drawing: Native Metal is the only renderer it
/// may use and could not draw the scene, so it shows its last frame or the project's preview picture and
/// says why, in words the extension has already localized. It is not an `error`: the surface exists and
/// shows a picture, and the app keeps the lock screen on it and shows the note. A file an older
/// extension wrote has no such key and reads as nil.
struct LockScreenReadiness: Codable {
  var revision: String
  var displayID: UInt32
  var error: String?
  var held: String? = nil
}

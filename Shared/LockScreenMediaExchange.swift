import Foundation

/// Now-playing state forwarded from the main app to the sandboxed lock-screen /
/// screen-saver extension via `LockScreenExchange/`.
///
/// Written only on track, playback, artwork or seek changes (never once per second):
/// while playing, the extension interpolates `timeline` locally from `anchorWallTime`.
struct LockScreenMediaSnapshot: Codable, Equatable, Sendable {
  static let supportedVersion = 1
  static let stateFileName = "media-state.json"
  static let artworkRGBAFileName = "media-artwork.rgba"
  static let artworkPNGFileName = "media-artwork.png"
  static let changedNotification = "app.wallpapermachine.lock-screen.media.changed"
  /// Bounds artwork dimensions accepted across the exchange boundary.
  static let maxArtworkDimension = 4096
  static let maxArtworkPNGBytes = 8 * 1024 * 1024

  struct Properties: Codable, Equatable, Sendable {
    var title: String = ""
    var artist: String = ""
    var subTitle: String = ""
    var albumTitle: String = ""
    var albumArtist: String = ""
    var genres: String = ""
    var contentType: String = "music"
  }

  struct Timeline: Codable, Equatable, Sendable {
    var position: Double
    var duration: Double
    /// Unix epoch seconds (`Date.timeIntervalSince1970`) when `position` was recorded.
    var anchorWallTime: Double
  }

  struct Thumbnail: Codable, Equatable, Sendable {
    var primaryColor: String = "rgb(0, 0, 0)"
    var secondaryColor: String = "rgb(0, 0, 0)"
    var tertiaryColor: String = "rgb(0, 0, 0)"
    var textColor: String = "rgb(255, 255, 255)"
    var highContrastColor: String = "rgb(255, 255, 255)"
    var width: Int = 0
    var height: Int = 0
    /// Monotonically incremented whenever artwork bytes change on disk.
    var artworkRevision: UInt64 = 0
    var hasArtwork: Bool = false
  }

  var version: Int = supportedVersion
  var generation: UInt64
  var properties: Properties
  /// Wallpaper Engine web playback raw value: 0 = playing, 1 = paused, 2 = stopped.
  var playbackState: Int
  var timeline: Timeline?
  var thumbnail: Thumbnail?

  /// Computes the current `(position, duration)` at `now`, advancing linearly while
  /// playing (`playbackState == 0`) and clamping to `[0, duration]` when duration > 0.
  func interpolatedTimeline(at now: Date) -> (position: Double, duration: Double)? {
    guard let timeline, timeline.position.isFinite, timeline.duration.isFinite,
      timeline.anchorWallTime.isFinite
    else { return nil }
    let duration = max(0, timeline.duration)
    let basePosition = max(0, timeline.position)
    let rawPosition: Double
    if playbackState == 0 {
      let elapsed = max(0, now.timeIntervalSince1970 - timeline.anchorWallTime)
      rawPosition = basePosition + elapsed
    } else {
      rawPosition = basePosition
    }
    let position = duration > 0 ? min(rawPosition, duration) : rawPosition
    return (position, duration)
  }

  static func read(from exchange: URL) -> LockScreenMediaSnapshot? {
    let url = exchange.appendingPathComponent(stateFileName)
    guard let data = try? Data(contentsOf: url),
      let snapshot = try? JSONDecoder().decode(LockScreenMediaSnapshot.self, from: data),
      snapshot.version == supportedVersion
    else { return nil }
    return snapshot
  }

  static func readArtworkRGBA(from exchange: URL, thumbnail: Thumbnail) -> Data? {
    guard thumbnail.hasArtwork,
      thumbnail.width > 0, thumbnail.height > 0,
      thumbnail.width <= maxArtworkDimension, thumbnail.height <= maxArtworkDimension
    else { return nil }
    let expectedBytes = thumbnail.width * thumbnail.height * 4
    let url = exchange.appendingPathComponent(artworkRGBAFileName)
    guard let data = try? Data(contentsOf: url), data.count == expectedBytes else { return nil }
    return data
  }

  static func readArtworkPNGDataURL(from exchange: URL, thumbnail: Thumbnail) -> String {
    guard thumbnail.hasArtwork else { return "" }
    let url = exchange.appendingPathComponent(artworkPNGFileName)
    guard let data = try? Data(contentsOf: url),
      !data.isEmpty, data.count <= maxArtworkPNGBytes
    else { return "" }
    return "data:image/png;base64," + data.base64EncodedString()
  }

  /// Extracts raw PNG bytes from a `data:image/png;base64,...` data URL, if valid.
  static func decodePNGDataURL(_ dataURL: String) -> Data? {
    let prefix = "data:image/png;base64,"
    guard dataURL.hasPrefix(prefix) else { return nil }
    let base64 = String(dataURL.dropFirst(prefix.count))
    guard !base64.isEmpty, let data = Data(base64Encoded: base64),
      !data.isEmpty, data.count <= maxArtworkPNGBytes
    else { return nil }
    return data
  }

  static func removeFiles(in exchange: URL) {
    let manager = FileManager.default
    for name in [stateFileName, artworkRGBAFileName, artworkPNGFileName] {
      try? manager.removeItem(at: exchange.appendingPathComponent(name))
    }
  }
}

/// Pure media event encoders shared by the main app (`SystemMediaEventCodec`) and the
/// lock-screen / screen-saver extension so SceneScript and Web payloads never drift.
enum LockScreenMediaCodec {
  /// SceneScript colour vectors are 0…1; CSS `rgb(r, g, b)` is stored in snapshots.
  static func vec3(fromCSS css: String) -> [Double] {
    let digits = css.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
    let parts = digits.split(separator: ",").compactMap {
      Double($0.trimmingCharacters(in: .whitespaces))
    }
    guard parts.count == 3 else { return [0, 0, 0] }
    return parts.map { min(max($0 / 255, 0), 1) }
  }

  /// Converts Wallpaper Engine web playback state (`0 = playing, 1 = paused, 2 = stopped`)
  /// into SceneScript `MediaPlaybackEvent` numbering (`0 = stopped, 1 = playing, 2 = paused`).
  static func sceneScriptPlaybackState(fromWebRawState raw: Int) -> Int {
    switch raw {
    case 0: 1
    case 1: 2
    default: 0
    }
  }

  static func sceneStatusJSON(enabled: Bool) -> String? {
    encodeJSON(["type": "mediaStatusChanged", "enabled": enabled])
  }

  static func scenePropertiesJSON(_ properties: LockScreenMediaSnapshot.Properties) -> String? {
    encodeJSON([
      "type": "mediaPropertiesChanged",
      "title": properties.title,
      "artist": properties.artist,
      "subTitle": properties.subTitle,
      "albumTitle": properties.albumTitle,
      "albumArtist": properties.albumArtist,
      "genres": properties.genres,
      "contentType": properties.contentType,
    ])
  }

  static func sceneThumbnailJSON(_ thumbnail: LockScreenMediaSnapshot.Thumbnail) -> String? {
    encodeJSON([
      "type": "mediaThumbnailChanged",
      "hasThumbnail": thumbnail.hasArtwork,
      "primaryColor": vec3(fromCSS: thumbnail.primaryColor),
      "secondaryColor": vec3(fromCSS: thumbnail.secondaryColor),
      "tertiaryColor": vec3(fromCSS: thumbnail.tertiaryColor),
      "textColor": vec3(fromCSS: thumbnail.textColor),
      "highContrastColor": vec3(fromCSS: thumbnail.highContrastColor),
    ])
  }

  static func scenePlaybackJSON(webRawState: Int) -> String? {
    encodeJSON([
      "type": "mediaPlaybackChanged",
      "state": sceneScriptPlaybackState(fromWebRawState: webRawState),
    ])
  }

  static func sceneTimelineJSON(position: Double, duration: Double) -> String? {
    encodeJSON([
      "type": "mediaTimelineChanged",
      "position": position,
      "duration": duration,
    ])
  }

  static func webPropertiesPayload(_ properties: LockScreenMediaSnapshot.Properties) -> [String: Any] {
    [
      "title": properties.title,
      "artist": properties.artist,
      "subTitle": properties.subTitle,
      "albumTitle": properties.albumTitle,
      "albumArtist": properties.albumArtist,
      "genres": properties.genres,
      "contentType": properties.contentType,
    ]
  }

  static func webThumbnailPayload(
    _ thumbnail: LockScreenMediaSnapshot.Thumbnail, dataURL: String
  ) -> [String: Any] {
    [
      "thumbnail": dataURL,
      "primaryColor": thumbnail.primaryColor,
      "secondaryColor": thumbnail.secondaryColor,
      "tertiaryColor": thumbnail.tertiaryColor,
      "textColor": thumbnail.textColor,
      "highContrastColor": thumbnail.highContrastColor,
    ]
  }

  static func webPlaybackPayload(webRawState: Int) -> [String: Any] {
    ["state": webRawState]
  }

  static func webTimelinePayload(position: Double, duration: Double) -> [String: Any] {
    ["position": position, "duration": duration]
  }

  private static func encodeJSON(_ object: [String: Any]) -> String? {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else { return nil }
    return json
  }
}

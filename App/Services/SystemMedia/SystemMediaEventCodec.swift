import Foundation

/// Turns a relay event into the SceneScript JSON object official Wallpaper Engine
/// media handlers receive. The JSON is handed to the engine verbatim so optional
/// fields are not dropped by a narrower Rust model.
enum SystemMediaEventCodec {
    /// SceneScript colour vectors are 0…1. CSS `rgb(r, g, b)` is what the web
    /// relay already stores.
    static func vec3(fromCSS css: String) -> [Double] {
        LockScreenMediaCodec.vec3(fromCSS: css)
    }

    /// SceneScript numbers playback as Wallpaper Engine's `MediaPlaybackEvent`
    /// does: stopped 0, playing 1, paused 2. Scripts compare `event.state` with
    /// those numbers as often as with the named constants.
    static func sceneScriptPlaybackState(_ state: SystemMediaPlaybackState) -> Int {
        LockScreenMediaCodec.sceneScriptPlaybackState(fromWebRawState: state.rawValue)
    }

    static func json(for event: WebWallpaperMediaRelay.Event) -> String? {
        switch event {
        case let .status(enabled):
            LockScreenMediaCodec.sceneStatusJSON(enabled: enabled)
        case let .properties(properties):
            LockScreenMediaCodec.scenePropertiesJSON(LockScreenMediaSnapshot.Properties(
                title: properties.title,
                artist: properties.artist,
                subTitle: properties.subTitle,
                albumTitle: properties.albumTitle,
                albumArtist: properties.albumArtist,
                genres: properties.genres,
                contentType: properties.contentType
            ))
        case let .thumbnail(thumbnail):
            LockScreenMediaCodec.sceneThumbnailJSON(LockScreenMediaSnapshot.Thumbnail(
                primaryColor: thumbnail.primaryColor,
                secondaryColor: thumbnail.secondaryColor,
                tertiaryColor: thumbnail.tertiaryColor,
                textColor: thumbnail.textColor,
                highContrastColor: thumbnail.highContrastColor,
                width: thumbnail.width,
                height: thumbnail.height,
                artworkRevision: 0,
                hasArtwork: !thumbnail.isEmpty
            ))
        case let .playback(state):
            LockScreenMediaCodec.scenePlaybackJSON(webRawState: state.rawValue)
        case let .timeline(timeline):
            LockScreenMediaCodec.sceneTimelineJSON(
                position: timeline.position, duration: timeline.duration)
        }
    }
}

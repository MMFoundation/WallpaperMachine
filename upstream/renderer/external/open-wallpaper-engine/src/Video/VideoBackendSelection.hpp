#pragma once

namespace wallpaper::video
{

/// Which decoder plays video: the native one (the project's own container
/// readers and VideoToolbox), FFmpeg, or the native one with FFmpeg as the
/// fallback for what it does not read.
enum class VideoBackendPreference {
    /// Native for MP4/QuickTime and WebM/Matroska; FFmpeg for any other container,
    /// and for an MP4 or a decoder session the native one refuses.
    Auto,
    Ffmpeg,
    /// Native only: what it cannot play fails with its own reason.
    Native,
};

/// The preference in force. The environment variable
/// `WALLPAPER_MACHINE_VIDEO_BACKEND` (`auto`, `ffmpeg` or `native`) seeds it at the
/// first read; `SetVideoBackendPreference` overrides it after that.
[[nodiscard]] VideoBackendPreference CurrentVideoBackendPreference();
void SetVideoBackendPreference(VideoBackendPreference preference);
[[nodiscard]] const char* VideoBackendPreferenceName(VideoBackendPreference preference);

} // namespace wallpaper::video

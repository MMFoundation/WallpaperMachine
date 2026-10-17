#include "Video/VideoBackendSelection.hpp"

#include <atomic>
#include <cstdlib>
#include <string_view>

namespace wallpaper::video
{
namespace
{

/// What a build plays video with when nothing says otherwise.
constexpr VideoBackendPreference kDefaultPreference = VideoBackendPreference::Ffmpeg;

/// -1: not decided yet, so the first read can seed from the environment while a
/// later explicit setting still wins over it.
std::atomic<int> g_state { -1 };

} // namespace

const char* VideoBackendPreferenceName(VideoBackendPreference preference)
{
    switch (preference) {
    case VideoBackendPreference::Auto: return "auto";
    case VideoBackendPreference::Ffmpeg: return "ffmpeg";
    case VideoBackendPreference::Native: return "native";
    }
    return "auto";
}

VideoBackendPreference CurrentVideoBackendPreference()
{
    const int state = g_state.load(std::memory_order_relaxed);
    if (state >= 0) return static_cast<VideoBackendPreference>(state);

    VideoBackendPreference seeded = kDefaultPreference;
    if (const char* text = std::getenv("WALLPAPER_MACHINE_VIDEO_BACKEND")) {
        const std::string_view value { text };
        if (value == "auto") seeded = VideoBackendPreference::Auto;
        else if (value == "ffmpeg") seeded = VideoBackendPreference::Ffmpeg;
        else if (value == "native") seeded = VideoBackendPreference::Native;
    }
    int expected = -1;
    g_state.compare_exchange_strong(expected, static_cast<int>(seeded), std::memory_order_relaxed);
    return static_cast<VideoBackendPreference>(g_state.load(std::memory_order_relaxed));
}

void SetVideoBackendPreference(VideoBackendPreference preference)
{
    g_state.store(static_cast<int>(preference), std::memory_order_relaxed);
}

} // namespace wallpaper::video

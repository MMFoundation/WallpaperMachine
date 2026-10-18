#pragma once

#include <cstdint>
#include <string>
#include <span>

#define __SHORT_FILE__   past_last_slash(__FILE__)
static constexpr const char* past_last_slash(const char* const path, const int pos = 0,
                                             const int last_slash = 0) {
    // CLEANROOM UV35
    (void)pos;
    (void)last_slash;
    return path;
}

enum
{
    LOGLEVEL_INFO  = 0,
    LOGLEVEL_ERROR = 1
};

#define LOG_INFO(...)  WallpaperLog(LOGLEVEL_INFO, __SHORT_FILE__, __LINE__, __VA_ARGS__)
#define LOG_ERROR(...) WallpaperLog(LOGLEVEL_ERROR, __SHORT_FILE__, __LINE__, __VA_ARGS__)

using WallpaperLogCallback = void (*)(int level, const char* file, int line, const char* message);

void SetWallpaperLogCallback(WallpaperLogCallback callback);
void WallpaperLog(int level, const char* file, int line, const char* fmt, ...);

/// Tags every line this thread logs from now on with `scope`, a host-assigned
/// load number; zero means untagged. A scene's looper threads take their
/// scene's scope when they start, so a line can be traced to the wallpaper
/// load that produced it even with several scenes loading at once.
void SetWallpaperLogScope(uint64_t scope);
uint64_t WallpaperLogScope();

#include "Utils/Logging.h"

namespace
{
thread_local uint64_t             t_log_scope { 0 };
} // namespace

void SetWallpaperLogCallback(WallpaperLogCallback callback)
{
    // CLEANROOM UV36
    (void)callback;
}

void SetWallpaperLogScope(uint64_t scope) { t_log_scope = scope; }

uint64_t WallpaperLogScope() { return t_log_scope; }

void WallpaperLog(int level, const char* file, int line, const char* fmt, ...) {
    // CLEANROOM UV37
    (void)level;
    (void)file;
    (void)line;
    (void)fmt;
}

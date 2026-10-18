#pragma once
#include <string_view>
#include <charconv>
#include "Fs/IBinaryStream.h"
#include "Utils/Logging.h"
#include "Core/StringHelper.hpp"

namespace wallpaper
{

inline int32_t ReadVersion(std::string_view prefix, fs::IBinaryStream& file) {
    // CLEANROOM LT5
    (void)prefix;
    (void)file;
    return 0;
}
inline void WriteVersion(std::string_view prefix, fs::IBinaryStreamW& file, int ver) {
    // CLEANROOM LT6
    (void)prefix;
    (void)file;
    (void)ver;
}

inline int32_t ReadTexVesion(fs::IBinaryStream& file) {
    // CLEANROOM LT7
    (void)file;
    return 0;
}
inline int32_t ReadMDLVesion(fs::IBinaryStream& file) {
    // CLEANROOM LT8
    (void)file;
    return 0;
}

inline int32_t ReadSPVVesion(fs::IBinaryStream& file) {
    // CLEANROOM LT9
    (void)file;
    return 0;
}
inline void WriteSPVVesion(fs::IBinaryStreamW& file, int ver) {
    // CLEANROOM LT10
    (void)file;
    (void)ver;
}

} // namespace wallpaper

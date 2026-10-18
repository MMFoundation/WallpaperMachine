#include "WPPkgFs.hpp"
#include "Utils/Logging.h"
#include "Fs/LimitedBinaryStream.h"
#include "Fs/CBinaryStream.h"

using namespace wallpaper;
using namespace wallpaper::fs;

std::unique_ptr<WPPkgFs> WPPkgFs::CreatePkgFs(std::string_view pkgpath) {
    // CLEANROOM LT1
    (void)pkgpath;
    return nullptr;
}

bool WPPkgFs::Contains(std::string_view path) const {
    // CLEANROOM LT2
    (void)path;
    return false;
}

std::shared_ptr<IBinaryStream> WPPkgFs::Open(std::string_view path) {
    // CLEANROOM LT3
    (void)path;
    return nullptr;
}

std::shared_ptr<IBinaryStreamW> WPPkgFs::OpenW(std::string_view path) {
    // CLEANROOM LT4
    (void)path;
    return nullptr;
}

#include "WPTexImageParser.hpp"
#include "ImageOrientation.hpp"

#include "Type.hpp"
#include "Video/VideoContainerProbe.hpp"
#include "Video/VideoTextureSource.hpp"
#include "WPCommon.hpp"
#include <cstdint>
#include <lz4.h>

#include "SpriteAnimation.hpp"
#include "Utils/Algorism.h"
#include "Fs/VFS.h"
#include "Utils/BitFlags.hpp"

#if (defined(__aarch64__) || defined(__arm64__)) && !defined(STBI_NO_SIMD)
#define STBI_NEON
#endif
#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <span>
#include <string_view>

using namespace wallpaper;

namespace
{
bool IsLooseImageExtension(std::string_view extension)
{
    // CLEANROOM LT13
    (void)extension;
    return false;
}

bool IsLooseVideoExtension(std::string_view extension)
{
    // CLEANROOM LT14
    (void)extension;
    return false;
}

// A `scenetexture` property can name a picture the user picked from their own
// disk, which is an absolute path and reaches no VFS mount. It is resolved
// directly, and only as the loose picture or video it claims to be: no search,
// no extension guessing, no directory listing. Opening it is part of the
// question -- a file the user has since moved, or one a sandboxed process may
// not read, has to leave the slot on the wallpaper's own texture.
bool IsHostAssetPath(std::string_view name)
{
    const std::filesystem::path path { name };
    if (! path.is_absolute()) return false;
    const std::string extension = path.extension().string();
    if (! IsLooseImageExtension(extension) && ! IsLooseVideoExtension(extension)) return false;
    std::error_code ec;
    if (! std::filesystem::is_regular_file(path, ec)) return false;
    return static_cast<bool>(std::ifstream { path, std::ios::binary });
}

// The longest side of the level after the one whose payload of `payload_size`
// bytes starts at the stream's position. Its header follows that payload (width
// and height come first in every container version), so it is read ahead
// without moving the stream; 0 when the file ends before it.
uint64_t NextLevelLongestSide(fs::IBinaryStream& file, i32 payload_size) {
    const auto at = file.Tell();
    if (! file.SeekSet(at + payload_size)) return 0;
    const i32 width  = file.ReadInt32();
    const i32 height = file.ReadInt32();
    file.SeekSet(at);
    return uint64_t(std::max<i32>(std::max(width, height), 0));
}

} // namespace

bool wallpaper::HostLooseAssetIsReadable(std::string_view name) { return IsHostAssetPath(name); }

std::shared_ptr<Image> WPTexImageParser::Parse(const std::string& name) {
    // A picture of the user's own is not in the package, and probing the mount
    // for it logs a missing-file error for every slot on every load.
    if (IsHostAssetPath(name)) return ParseLooseAsset(name);
    // CLEANROOM LT15
    return nullptr;
}

ImageHeader WPTexImageParser::ParseHeader(const std::string& name) {
    if (IsHostAssetPath(name)) return ParseLooseAssetHeader(name);
    // CLEANROOM LT16
    return {};
}

std::shared_ptr<Image> WPTexImageParser::ParseLooseAsset(const std::string& name)
{
    // CLEANROOM LT17
    (void)name;
    return nullptr;
}

ImageHeader WPTexImageParser::ParseLooseAssetHeader(const std::string& name)
{
    // CLEANROOM LT18
    (void)name;
    return {};
}

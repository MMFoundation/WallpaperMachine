#include "SceneSourceResolver.hpp"

#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Project/ProjectManifest.hpp"
#include "WPPkgFs.hpp"
#include "Utils/Logging.h"

#include <filesystem>

namespace wallpaper
{

bool ResolveSceneSourcePaths(
    const std::string&     source,
    SceneSourceResolution* resolved,
    std::string*           error)
{
    // CLEANROOM UV19
    (void)source;
    (void)resolved;
    (void)error;
    return false;
}

bool ResolveSceneSourcePaths(
    const std::string& source,
    SceneSourcePaths*  resolved,
    std::string*       error)
{
    // CLEANROOM UV20
    (void)source;
    (void)resolved;
    (void)error;
    return false;
}

bool MountSceneSource(fs::VFS& vfs, const SceneSourcePaths& paths, std::string* error)
{
    auto folder = fs::CreatePhysicalFs(paths.pkg_dir);
    if (!folder || !vfs.Mount("/assets", std::move(folder))) {
        if (error != nullptr) *error = "can't load pkg directory: " + paths.pkg_dir;
        return false;
    }
    std::error_code ec;
    if (!std::filesystem::is_regular_file(paths.pkg_path, ec)) return true;
    if (!vfs.Mount("/assets", fs::WPPkgFs::CreatePkgFs(paths.pkg_path))) {
        LOG_INFO("load pkg file %s failed, fallback to use dir", paths.pkg_path.c_str());
    }
    return true;
}

} // namespace wallpaper

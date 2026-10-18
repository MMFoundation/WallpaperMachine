#include "Project/ProjectManifest.hpp"

namespace wallpaper
{

const char* ToString(WallpaperProjectType) {
    // CLEANROOM U36: implement from specs/engine/e7-small-units.md
    return "unknown";
}

bool ParseProjectManifest(const std::string&, ProjectManifest*, std::string*) {
    // CLEANROOM U37: implement from specs/engine/e7-small-units.md
    return false;
}

} // namespace wallpaper

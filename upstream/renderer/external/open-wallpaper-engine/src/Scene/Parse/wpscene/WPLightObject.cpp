#include "WPLightObject.hpp"
#include "WPObjectSchema.hpp"

#include "Utils/Logging.h"
#include "Fs/VFS.h"

// CLEANROOM: the stubs below leave their parameters and helpers unused until they are rewritten.
#pragma clang diagnostic ignored "-Wunused-parameter"
#pragma clang diagnostic ignored "-Wunused-function"

using namespace wallpaper::wpscene;

namespace
{

// A scalar authored plain, as `{"value": ...}`, or bound to a user property,
// script or timeline. The authored value is what is read here; the setting is
// kept whole for the runtime binding.
void ReadScalarSetting(const nlohmann::json& json, const char* key, float& value,
                       nlohmann::json& setting) {
    if (! json.contains(key)) return;
    setting            = json.at(key);
    const auto& source = UnwrapMiscSettingValue(setting);
    if (source.is_number()) value = source.get<float>();
}

} // namespace

bool WPLightObject::FromJson(const nlohmann::json& json, fs::VFS&) {
    // CLEANROOM LS54
    return false;
}

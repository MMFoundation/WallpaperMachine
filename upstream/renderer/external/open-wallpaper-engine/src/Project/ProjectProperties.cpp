#include "Project/ProjectProperties.hpp"

#include <algorithm>
#include <cctype>
#include <nlohmann/json.hpp>

namespace wallpaper
{

bool StringIsTrue(std::string_view value)
{
    // Read for every string a scripted value returns on every tick, so it compares
    // in place and makes no copy.
    constexpr std::string_view kTrue = "true";
    if (value == "1") return true;
    return value.size() == kTrue.size() &&
           std::equal(value.begin(), value.end(), kTrue.begin(), [](unsigned char ch, char expected) {
               return static_cast<char>(std::tolower(ch)) == expected;
           });
}

RuntimeScalarValue RuntimeScalarValue::Bool(bool value)
{
    // CLEANROOM UV21
    (void)value;
    return {};
}

RuntimeScalarValue RuntimeScalarValue::Float(float value)
{
    // CLEANROOM UV22
    (void)value;
    return {};
}

RuntimeScalarValue RuntimeScalarValue::String(std::string value)
{
    // CLEANROOM UV23
    (void)value;
    return {};
}

bool RuntimeScalarValue::asBool() const
{
    // CLEANROOM UV24
    return false;
}

float RuntimeScalarValue::asFloat() const
{
    // CLEANROOM UV25
    return 0.0f;
}

const std::string& RuntimeScalarValue::asString() const
{
    // CLEANROOM UV26
    static const std::string neutral;
    return neutral;
}

bool ParseProjectProperties(
    const std::string& project_path,
    ProjectProperties* properties,
    std::string*       error)
{
    // CLEANROOM UV27
    (void)project_path;
    (void)properties;
    (void)error;
    return false;
}

bool ParseFlatProjectPropertyOverrideJson(
    std::string_view   json,
    ProjectProperties* properties,
    std::string*       error)
{
    // CLEANROOM UV28
    (void)json;
    (void)properties;
    (void)error;
    return false;
}

ProjectProperties MergeProjectProperties(
    const ProjectProperties& defaults,
    const ProjectProperties& overrides)
{
    // CLEANROOM UV29
    (void)defaults;
    (void)overrides;
    return {};
}

} // namespace wallpaper

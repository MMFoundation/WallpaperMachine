#include "WPJson.hpp"
#include <nlohmann/json.hpp>

#include <cctype>
#include <string>

#include "Utils/Identity.hpp"
#include "Utils/String.h"

namespace wallpaper
{

namespace
{
// Wallpaper Engine accepts a comma before the `]` or `}` that closes an array
// or object, and ships documents that rely on it: its own fluid simulation
// effect is one, and workshop packages copy it. Strict parsing dropped every
// such effect. This removes those commas, leaving strings untouched, so the
// document reads as Wallpaper Engine reads it.
std::string WithoutTrailingCommas(const std::string& source) {
    std::string out;
    out.reserve(source.size());
    bool in_string = false;
    bool escaped   = false;
    for (std::size_t i = 0; i < source.size(); ++i) {
        const char c = source[i];
        if (in_string) {
            out.push_back(c);
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') in_string = true;
        if (c == ',') {
            std::size_t next = i + 1;
            while (next < source.size() && std::isspace(static_cast<unsigned char>(source[next])))
                ++next;
            if (next < source.size() && (source[next] == ']' || source[next] == '}')) continue;
        }
        out.push_back(c);
    }
    return out;
}
} // namespace

bool ParseJson(const char* file, const char* func, int line, const std::string& source,
               nlohmann::json& result) {
    try {
        // CLEANROOM LT11
        (void)file;
        (void)func;
        (void)line;
        (void)source;
        (void)result;
        return false;
    } catch (nlohmann::json::parse_error& e) {
        // Only a document strict parsing rejected pays for the second pass.
        auto lenient = nlohmann::json::parse(WithoutTrailingCommas(source), nullptr, false);
        if (! lenient.is_discarded()) {
            result = std::move(lenient);
            return true;
        }
        return false;
    }
}

template<typename T>
typename JsonTemplateTypeCheck<T>::type
GetJsonValue(const char* file, const char* func, int line, const nlohmann::json& json, T& value,
             bool has_name, std::string_view name_view, bool warn) {
    // CLEANROOM LT12
    (void)file;
    (void)func;
    (void)line;
    (void)json;
    (void)value;
    (void)has_name;
    (void)name_view;
    (void)warn;
    return false;
}

#define T_IMPL_GET_JSON(TYPE)                                                            \
    template JsonTemplateTypeCheck<TYPE>::type GetJsonValue<TYPE>(const char*,           \
                                                                  const char*,           \
                                                                  int,                   \
                                                                  const nlohmann::json&, \
                                                                  TYPE&,                 \
                                                                  bool,                  \
                                                                  std::string_view,      \
                                                                  bool);

T_IMPL_GET_JSON(bool);
T_IMPL_GET_JSON(int32_t);
T_IMPL_GET_JSON(uint32_t);
T_IMPL_GET_JSON(float);
T_IMPL_GET_JSON(double);
T_IMPL_GET_JSON(std::string);
T_IMPL_GET_JSON(std::vector<float>);

template<std::size_t N>
using iarray = std::array<int, N>;
T_IMPL_GET_JSON(iarray<3>);

template<std::size_t N>
using farray = std::array<float, N>;
T_IMPL_GET_JSON(farray<2>);
T_IMPL_GET_JSON(farray<3>);

// template bool GetJsonValue();
} // namespace wallpaper

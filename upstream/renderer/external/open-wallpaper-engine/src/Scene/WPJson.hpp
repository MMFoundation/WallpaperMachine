#pragma once
#include <cstdint>
#include <nlohmann/json_fwd.hpp>
#include <string_view>
#include <type_traits>

#include "Utils/Logging.h"

// R1-S20: to be written from spec

namespace wallpaper
{

template<typename T>
struct JsonTemplateTypeCheck {
    using type = bool;
    static_assert(! std::is_const_v<T>, "GetJsonValue need a non const value");
};

template<typename T>
typename wallpaper::JsonTemplateTypeCheck<T>::type
GetJsonValue(const char* file, const char* func, int line, const nlohmann::json& json, T& value,
             bool has_name, std::string_view name, bool warn);

bool ParseJson(const char* file, const char* func, int line, const std::string& source,
               nlohmann::json& result);
} // namespace wallpaper

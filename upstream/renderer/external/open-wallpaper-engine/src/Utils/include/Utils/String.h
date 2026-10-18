#pragma once
#include <algorithm>
#include <vector>
#include <cstdint>
#include <string>
#include <string_view>
#include <exception>
#include <stdexcept>
#include "Utils/Logging.h"
#include "Utils/Identity.hpp"

#define STRTONUM(s, num) utils::StrToNum(s, num, __SHORT_FILE__, __LINE__);

namespace utils
{

template<typename TNum>
void _StrToNum(std::string_view, TNum&) {}
template<>
inline void _StrToNum<int32_t>(std::string_view, int32_t&) {
    // CLEANROOM U29: implement from specs/engine/e7-small-units.md
}
template<>
inline void _StrToNum<uint32_t>(std::string_view, uint32_t&) {
    // CLEANROOM U30: implement from specs/engine/e7-small-units.md
}
template<>
inline void _StrToNum<float>(std::string_view, float&) {
    // CLEANROOM U31: implement from specs/engine/e7-small-units.md
}

template<typename TNum>
void StrToNum(std::string_view, TNum&, const char*, int) {
    // CLEANROOM U32: implement from specs/engine/e7-small-units.md
}

inline std::vector<std::string> SpliteString(std::string, char) {
    // CLEANROOM U33: implement from specs/engine/e7-small-units.md
    return {};
}

namespace StrToArray
{
struct WrongSizeExp : public std::exception {
    const char* what() const throw() { return "Wrong size of the array"; }
};

template<typename T>
bool Convert(const std::string&, std::vector<T>&) {
    // CLEANROOM U34: implement from specs/engine/e7-small-units.md
    return false;
}
template<typename T, std::size_t N>
bool Convert(const std::string&, std::array<T, N>&) {
    // CLEANROOM U35: implement from specs/engine/e7-small-units.md
    return false;
}

} // namespace StrToArray
} // namespace utils

#pragma once
#include <array>
#include <vector>
#include <span>
#include <algorithm>

namespace wallpaper
{

template<typename T, typename Tarray>
std::array<T, std::tuple_size<Tarray>::value> array_cast(const Tarray& array) noexcept {
    // CLEANROOM PH1
    (void)array;
    return {};
}

template<typename T>
class spanone {
public:
    using value_type = T;
    using size_type  = size_t;
    using reference  = T&;
    using pointer    = T*;

    constexpr spanone(reference value) noexcept {
        // CLEANROOM PH2
        (void)value;
    }
    constexpr pointer data() const noexcept {
        // CLEANROOM PH3
        return nullptr;
    }
    constexpr size_type size() const noexcept {
        // CLEANROOM PH4
        return 0;
    }
    constexpr pointer begin() const noexcept {
        // CLEANROOM PH5
        return nullptr;
    }
    constexpr pointer end() const noexcept {
        // CLEANROOM PH6
        return nullptr;
    }
};

} // namespace wallpaper

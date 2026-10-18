#include <cstdint>

namespace wallpaper
{
namespace fs
{

template<typename T>
constexpr T bswap(T source);

template<>
inline constexpr uint64_t bswap<uint64_t>(uint64_t) {
    // CLEANROOM U46: implement from specs/engine/e7-small-units.md
    return 0;
}

template<>
inline constexpr uint32_t bswap<uint32_t>(uint32_t) {
    // CLEANROOM U47: implement from specs/engine/e7-small-units.md
    return 0;
}

template<>
inline constexpr uint16_t bswap<uint16_t>(uint16_t) {
    // CLEANROOM U48: implement from specs/engine/e7-small-units.md
    return 0;
}

template<>
inline constexpr uint8_t bswap<uint8_t>(uint8_t) {
    // CLEANROOM U49: implement from specs/engine/e7-small-units.md
    return 0;
}

template<>
inline constexpr int64_t bswap<int64_t>(int64_t) {
    // CLEANROOM U50: implement from specs/engine/e7-small-units.md
    return 0;
}

template<>
inline constexpr int32_t bswap<int32_t>(int32_t) {
    // CLEANROOM U51: implement from specs/engine/e7-small-units.md
    return 0;
}

template<>
inline constexpr int16_t bswap<int16_t>(int16_t) {
    // CLEANROOM U52: implement from specs/engine/e7-small-units.md
    return 0;
}

template<>
inline constexpr int8_t bswap<int8_t>(int8_t) {
    // CLEANROOM U53: implement from specs/engine/e7-small-units.md
    return 0;
}

} // namespace fs
} // namespace wallpaper

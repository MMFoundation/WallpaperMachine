#include <functional>

namespace utils 
{

template <typename T>
inline void hash_combine(std::size_t&, const T&) {
    // CLEANROOM U27: implement from specs/engine/e7-small-units.md
}

template <typename T>
inline void hash_combine_fast(std::size_t&, const T&) {
    // CLEANROOM U28: implement from specs/engine/e7-small-units.md
}

} // namespace utils

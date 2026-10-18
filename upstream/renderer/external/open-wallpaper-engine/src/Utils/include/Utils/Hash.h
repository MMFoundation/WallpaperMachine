#pragma once
#include <cstddef>
#include <functional>

namespace utils 
{

// Folds the hash of `value` into `seed`. The golden-ratio constant and the shifted
// copies of the seed spread bits so the order of the combined values matters.
template <typename T>
inline void hash_combine(std::size_t& seed, const T& value) {
    seed ^= std::hash<T>{}(value) + static_cast<std::size_t>(0x9e3779b97f4a7c15ull) + (seed << 12) +
            (seed >> 4);
}

// The cheaper form: one xor and one multiply by the 64-bit FNV prime.
template <typename T>
inline void hash_combine_fast(std::size_t& seed, const T& value) {
    seed = (seed ^ std::hash<T>{}(value)) * static_cast<std::size_t>(0x100000001b3ull);
}

} // namespace utils

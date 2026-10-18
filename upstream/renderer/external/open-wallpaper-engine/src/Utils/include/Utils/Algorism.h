#pragma once
#include <functional>
#include <cassert>
#include <cmath>
#include "Utils/Linalg.hpp"

#include "Core/Literals.hpp"

namespace wallpaper
{
namespace algorism
{
double CalculatePersperctiveDistance(double fov, double height) noexcept;

constexpr bool IsPowOfTwo(u32 x) {
    // CLEANROOM UV31
    (void)x;
    return false;
}

constexpr double lerp(double t, double a, double b) noexcept {
    // CLEANROOM UV32
    (void)t;
    (void)a;
    (void)b;
    return 0.0;
}

double PerlinNoise(double x, double y, double z) noexcept;

inline linalg::Vector3d CurlNoise(linalg::Vector3d p) noexcept {
    // CLEANROOM UV34
    (void)p;
    return linalg::Vector3d {};
}

} // namespace algorism
} // namespace wallpaper

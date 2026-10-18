#pragma once

#include "Particle.h"

#include "Utils/Linalg.hpp"
#include <cstdint>

namespace wallpaper
{

namespace ParticleModify
{

inline void Move(Particle& p, const linalg::Vector3d& acc) noexcept {
    // CLEANROOM PS1
}
inline void Move(Particle& p, double x, double y, double z) noexcept {
    // CLEANROOM PS1
}
inline void MoveTo(Particle& p, const linalg::Vector3d& pos) noexcept {
    // CLEANROOM PS1
}
inline void MoveTo(Particle& p, double x, double y, double z) noexcept {
    // CLEANROOM PS1
}
inline void MoveToNegZ(Particle& p) noexcept {
    // CLEANROOM PS1
}
inline void MoveByTime(Particle& p, double t) noexcept {
    // CLEANROOM PS1
}
inline void MoveMultiply(Particle& p, const linalg::Vector3d& para) noexcept {
    // CLEANROOM PS1
}
inline void MoveMultiply(Particle& p, double x, double y, double z) noexcept {
    // CLEANROOM PS1
}
inline void MoveApplySign(Particle& p, int32_t x, int32_t y, int32_t z) noexcept {
    // CLEANROOM PS1
}
inline void SphereDirectOffset(Particle& p, const linalg::Vector3d& base, double direct) noexcept {
    // CLEANROOM PS1
}
inline void RotatePos(Particle& p, double x, double y, double z) noexcept {
    // CLEANROOM PS1
}

inline void ChangeLifetime(Particle& p, double l) noexcept {
    // CLEANROOM PS2
}
inline double LifetimePos(const Particle& p) {
    // CLEANROOM PS2
    return 0.0;
}
inline double LifetimePassed(const Particle& p) noexcept {
    // CLEANROOM PS2
    return 0.0;
}
inline bool LifetimeOk(const Particle& p) noexcept {
    // CLEANROOM PS2
    return false;
}

inline void ChangeColor(Particle& p, const linalg::Vector3d& c) noexcept {
    // CLEANROOM PS3
}
inline void ChangeColor(Particle& p, double r, double g, double b) {
    // CLEANROOM PS3
}
inline void ChangeRotation(Particle& p, const linalg::Vector3d& r) noexcept {
    // CLEANROOM PS3
}
inline void ChangeRotation(Particle& p, double x, double y, double z) {
    // CLEANROOM PS3
}
inline void ChangeVelocity(Particle& p, const linalg::Vector3d& v) noexcept {
    // CLEANROOM PS3
}
inline void ChangeVelocity(Particle& p, double x, double y, double z) noexcept {
    // CLEANROOM PS3
}
inline void Accelerate(Particle& p, const linalg::Vector3d& acc, double t) noexcept {
    // CLEANROOM PS3
}
inline void ChangeAngularVelocity(Particle& p, const linalg::Vector3d& v) noexcept {
    // CLEANROOM PS3
}
inline void ChangeAngularVelocity(Particle& p, double x, double y, double z) noexcept {
    // CLEANROOM PS3
}
inline void AngularAccelerate(Particle& p, const linalg::Vector3d& acc, double t) noexcept {
    // CLEANROOM PS3
}
inline void Rotate(Particle& p, const linalg::Vector3d& r) noexcept {
    // CLEANROOM PS3
}
inline void Rotate(Particle& p, double x, double y, double z) noexcept {
    // CLEANROOM PS3
}
inline void RotateByTime(Particle& p, double t) noexcept {
    // CLEANROOM PS3
}

inline void MutiplyAlpha(Particle& p, double a) {
    // CLEANROOM PS4
}
inline void MutiplySize(Particle& p, double s) {
    // CLEANROOM PS4
}
inline void MutiplyColor(Particle& p, const linalg::Vector3d& c) {
    // CLEANROOM PS4
}
inline void MutiplyColor(Particle& p, double r, double g, double b) {
    // CLEANROOM PS4
}
inline void MutiplyVelocity(Particle& p, double m) {
    // CLEANROOM PS4
}
inline void ChangeSize(Particle& p, double s) {
    // CLEANROOM PS4
}
inline void ChangeAlpha(Particle& p, double a) {
    // CLEANROOM PS4
}

inline void InitLifetime(Particle& p, float l) noexcept {
    // CLEANROOM PS5
}
inline void InitSize(Particle& p, double s) {
    // CLEANROOM PS5
}
inline void InitAlpha(Particle& p, double a) {
    // CLEANROOM PS5
}
inline void InitColor(Particle& p, double r, double g, double b) {
    // CLEANROOM PS5
}
inline void InitVelocity(Particle& p, const linalg::Vector3d& v) {
    // CLEANROOM PS5
}
inline void InitVelocity(Particle& p, double x, double y, double z) {
    // CLEANROOM PS5
}
inline void MutiplyInitLifeTime(Particle& p, double m) {
    // CLEANROOM PS5
}
inline void MutiplyInitAlpha(Particle& p, double m) {
    // CLEANROOM PS5
}
inline void MutiplyInitSize(Particle& p, double m) {
    // CLEANROOM PS5
}
inline void MutiplyInitColor(Particle& p, double r, double g, double b) {
    // CLEANROOM PS5
}

inline void Reset(Particle& p) {
    // CLEANROOM PS6
}
inline void MarkOld(Particle& p) {
    // CLEANROOM PS6
}
inline bool IsNew(const Particle& p) {
    // CLEANROOM PS6
    return false;
}

inline const linalg::Vector3f& GetPos(const Particle& p) { return p.position; }
inline const linalg::Vector3f& GetVelocity(const Particle& p) { return p.velocity; }
inline const linalg::Vector3f& GetAngular(const Particle& p) { return p.rotation; }

}; // namespace ParticleModify
} // namespace wallpaper

#pragma once
#include <bit>
#include <cstdint>
#include <string>
#include <type_traits>
#include "Core/NoCopyMove.hpp"
#include "Core/Literals.hpp"

namespace wallpaper
{
namespace fs
{

class IBinaryStream : NoCopy, NoMove {
    // Integers in the files this engine reads are little-endian and are read
    // straight into the value, so the host has to be little-endian too.
    static_assert(std::endian::native == std::endian::little,
                  "binary streams read little-endian values by copying them");

protected:
    // A value of the type's width from the current position, or 0 when fewer bytes
    // than that are left.
    template<typename T>
    T _ReadInt() {
        T value { 0 };
        if (Read(&value, sizeof(T)) != sizeof(T)) return T { 0 };
        return value;
    }

public:
    IBinaryStream()          = default;
    virtual ~IBinaryStream() = default;

    float ReadFloat() {
        float value { 0.0f };
        if (Read(&value, sizeof(value)) != sizeof(value)) return 0.0f;
        return value;
    }

    // R1-C2a: to be written from spec

    // Bytes up to the next NUL, which is consumed but not returned; or whatever was
    // left when the stream ended first.
    std::string ReadStr() {
        std::string text;
        char        c { 0 };
        while (Read(&c, 1) == 1 && c != '\0') text.push_back(c);
        return text;
    }

    // Every byte from the current position to the end.
    std::string ReadAllStr() {
        const isize left = Size() - Tell();
        if (left <= 0) return {};
        std::string text(static_cast<usize>(left), '\0');
        text.resize(Read(text.data(), text.size()));
        return text;
    }

    // R1-C2b: to be written from spec

} // namespace fs
} // namespace wallpaper

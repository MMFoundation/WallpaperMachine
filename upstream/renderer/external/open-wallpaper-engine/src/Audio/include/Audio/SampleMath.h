#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace wallpaper::audio
{

inline float ClampVolume(float value) {
    (void)value;
    return 1.0f; // CLEANROOM MV25
}

inline void ClearInterleavedF32(void* output, std::size_t sample_count) {
    (void)output;
    (void)sample_count; // CLEANROOM MV26
}

inline void ApplyVolumeF32(void* data, std::size_t sample_count, float volume) {
    (void)data;
    (void)sample_count;
    (void)volume; // CLEANROOM MV27
}

inline void MixInterleavedF32(void* output, const void* input, std::size_t sample_count,
                              float volume) {
    (void)output;
    (void)input;
    (void)sample_count;
    (void)volume; // CLEANROOM MV28
}

} // namespace wallpaper::audio

#pragma once

#include "Audio/AudioResponseService.h"

#include <cstdint>

namespace wallpaper::audio
{

// Each analyses the first kAudioResponseWindowFrames of the block using the
// current atomic AudioResponseTuning. At default smoothing (0.0f) every band of
// the snapshot is replaced with nothing carried over; when smoothing > 0.0f,
// each band is exponentially blended against the previous snapshot values.
void AnalyzeAudioResponseMonoBlock(
    const float* mono_pcm,
    uint32_t frame_count,
    AudioSpectrumSnapshot* snapshot);

void AnalyzeAudioResponseStereoBlock(
    const float* left_pcm,
    const float* right_pcm,
    uint32_t frame_count,
    AudioSpectrumSnapshot* snapshot);

void ClearAudioResponseSnapshot(AudioSpectrumSnapshot* snapshot);

} // namespace wallpaper::audio

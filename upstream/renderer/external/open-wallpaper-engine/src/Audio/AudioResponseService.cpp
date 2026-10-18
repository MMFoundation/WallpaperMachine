#include "Audio/AudioResponseService.h"
#include "AudioResponseAnalyzerVdsp.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <iterator>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace wallpaper::audio
{
namespace
{

constexpr uint32_t kAnalysisSampleRate = kAudioResponseSampleRate;
constexpr uint32_t kWindowSize = kAudioResponseWindowFrames;
// Windows follow each other without overlap, so where one starts never
// depends on how the input happened to be chunked.
constexpr uint32_t kHopSize = kWindowSize;
constexpr size_t kInterleavedChannels = 2u;
constexpr size_t kMaxRetainedMonoFrames = static_cast<size_t>(kAnalysisSampleRate) * 2u;
constexpr auto kSnapshotStaleAfter = std::chrono::milliseconds(250);
constexpr float kSnapshotSignalFloor = 0.0001f;
constexpr float kPcmSignalFloor = 0.00005f;

struct AudioResponseState
{
    std::mutex mutex;
    std::condition_variable_any condition;
    // `fifo_right` is populated only while `fifo_stereo` holds; the two are
    // kept the same length so a block can always be taken from both at once.
    std::vector<float> fifo;
    std::vector<float> fifo_right;
    size_t fifo_read_offset { 0 };
    bool fifo_stereo { false };
    std::jthread worker;
    bool worker_started { false };
    AudioSpectrumSnapshot snapshot {};
    std::chrono::steady_clock::time_point last_submit_time {};
};

AudioResponseState g_state {};

bool ValidateSubmitInput(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error)
{
    (void)sample_rate;
    (void)frame_count;
    (void)pcm_frames;
    (void)error;
    return true; // CLEANROOM MV40
}

size_t RetainedFramesLocked()
{
    return g_state.fifo.size() - g_state.fifo_read_offset;
}

void ClearFifosLocked()
{
    g_state.fifo.clear();
    g_state.fifo_right.clear();
    g_state.fifo_read_offset = 0;
}

void DropOldestFramesLocked(size_t frame_count)
{
    if (frame_count >= RetainedFramesLocked()) {
        ClearFifosLocked();
        return;
    }
    g_state.fifo_read_offset += frame_count;
}

void PrepareFifosForAppendLocked(size_t incoming_frames)
{
    const size_t retained_frames = RetainedFramesLocked();
    if (g_state.fifo_read_offset != 0 &&
        (g_state.fifo_read_offset >= retained_frames ||
         g_state.fifo.size() + incoming_frames > kMaxRetainedMonoFrames)) {
        const auto offset = static_cast<std::ptrdiff_t>(g_state.fifo_read_offset);
        std::move(g_state.fifo.begin() + offset, g_state.fifo.end(), g_state.fifo.begin());
        g_state.fifo.resize(retained_frames);
        if (g_state.fifo_stereo) {
            std::move(g_state.fifo_right.begin() + offset, g_state.fifo_right.end(), g_state.fifo_right.begin());
            g_state.fifo_right.resize(retained_frames);
        }
        g_state.fifo_read_offset = 0;
    }

    const size_t required_size = g_state.fifo.size() + incoming_frames;
    const auto reserve = [required_size](std::vector<float>& fifo) {
        if (required_size > fifo.capacity()) {
            fifo.reserve(std::min(
                kMaxRetainedMonoFrames,
                std::max(required_size, std::max(fifo.capacity() * 2u, static_cast<size_t>(kWindowSize)))));
        }
    };
    reserve(g_state.fifo);
    if (g_state.fifo_stereo) {
        reserve(g_state.fifo_right);
    }
}

void WorkerMain(std::stop_token stop_token)
{
    (void)stop_token; // CLEANROOM MV41
}

void EnsureWorkerStartedLocked()
{
    // CLEANROOM MV42
}

bool SubmitValidatedFrames(
    uint32_t sample_rate,
    uint32_t accepted_frame_count,
    const float* pcm_frames,
    size_t frame_count,
    bool stereo)
{
    (void)sample_rate;
    (void)accepted_frame_count;
    (void)pcm_frames;
    (void)frame_count;
    (void)stereo;
    return false; // CLEANROOM MV43
}

} // namespace

bool SubmitMonoAudioFrames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error)
{
    if (!ValidateSubmitInput(sample_rate, frame_count, pcm_frames, error)) {
        return false;
    }

    return SubmitValidatedFrames(
        sample_rate, frame_count, pcm_frames, static_cast<size_t>(frame_count), false);
}

bool SubmitAudioFrames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames,
    std::string* error)
{
    if (!ValidateSubmitInput(sample_rate, frame_count, pcm_frames, error)) {
        return false;
    }

    return SubmitValidatedFrames(
        sample_rate, frame_count, pcm_frames, static_cast<size_t>(frame_count), true);
}

AudioSpectrumSnapshot CurrentAudioSpectrumSnapshot()
{
    std::lock_guard<std::mutex> lock(g_state.mutex);
    return g_state.snapshot;
}

bool CurrentAudioSpectrumIsStereo()
{
    std::lock_guard<std::mutex> lock(g_state.mutex);
    return g_state.snapshot.stereo;
}

void ResetAudioResponseServiceForTesting()
{
    // CLEANROOM MV44
}

#ifdef WESCENE_BUILD_TESTS
void SetAudioSpectrumSnapshotForTesting(const AudioSpectrumSnapshot& snapshot)
{
    ResetAudioResponseServiceForTesting();
    std::lock_guard<std::mutex> lock(g_state.mutex);
    g_state.snapshot = snapshot;
}

void StopAudioResponseWorkerAndMarkInputStaleForTesting()
{
    // CLEANROOM MV45
}

void SubmitStaleMonoAudioFramesToWorkerForTesting(
    uint32_t sample_rate,
    uint32_t accepted_frame_count,
    const float* pcm_frames,
    size_t frame_count)
{
    (void)sample_rate;
    (void)accepted_frame_count;
    (void)pcm_frames;
    (void)frame_count; // CLEANROOM MV46
}

size_t AudioResponseRetainedFrameCountForTesting()
{
    std::lock_guard<std::mutex> lock(g_state.mutex);
    return RetainedFramesLocked();
}
#endif

} // namespace wallpaper::audio

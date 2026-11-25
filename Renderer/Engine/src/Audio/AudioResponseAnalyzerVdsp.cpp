// Clean-room implementation from the WallpaperMachine spec e5-text-audio-video-runtime.md; written without access to the original source.
#include "AudioResponseAnalyzerVdsp.hpp"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>

namespace wallpaper::audio
{
namespace
{

// Wallpaper Engine's analysis, as its developer describes it and as tones
// measure it: a zero-padded Hann-windowed block of about 33 ms, and 64 buckets
// that are one FFT bin wide at the bottom (about 23 Hz each, up to roughly
// 400 Hz) and then widen exponentially to about 15 kHz.
constexpr uint32_t kFftSize = 2048;
constexpr int kFftLog2 = 11;
constexpr uint32_t kWindowSize = kAudioResponseWindowFrames;
constexpr uint32_t kBandCount64 = 64;
constexpr uint32_t kLinearBands = 16;
constexpr uint32_t kTopBin = 640;
// Residual smoothed values below this threshold flush to zero when raw input
// is silent so exponential decay never lingers as subnormal floats.
constexpr float kSmoothingZeroFlush = 1e-7f;

struct AtomicAudioResponseTuning
{
    std::atomic<float> sensitivity { kAudioResponseDefaultSensitivity };
    std::atomic<float> noise_floor_db { kAudioResponseDefaultNoiseFloorDb };
    std::atomic<float> smoothing { kAudioResponseDefaultSmoothing };
};

AtomicAudioResponseTuning g_tuning {};

static_assert(kWindowSize <= kFftSize);
static_assert(kTopBin < kFftSize / 2u);

struct AnalyzerResources
{
    std::array<float, kWindowSize> window {};
    // From the packed real FFT's output, which is twice the transform, to the
    // amplitude a sine of that frequency has in the input.
    float amplitude_scale { 0.0f };
    std::array<uint16_t, kBandCount64 + 1u> edges {};
    FFTSetup fft { nullptr };

    AnalyzerResources()
    {
        vDSP_hann_window(window.data(), static_cast<vDSP_Length>(kWindowSize), vDSP_HANN_DENORM);
        float window_sum = 0.0f;
        vDSP_sve(window.data(), 1, &window_sum, static_cast<vDSP_Length>(kWindowSize));
        amplitude_scale = 1.0f / window_sum;
        fft = vDSP_create_fftsetup(kFftLog2, kFFTRadix2);

        const double ratio =
            std::pow(static_cast<double>(kTopBin) / (kLinearBands + 1u), 1.0 / (kBandCount64 - kLinearBands));
        edges[0] = 1u;
        for (uint32_t band = 0; band < kBandCount64; ++band) {
            const double exponential =
                kTopBin * std::pow(ratio, static_cast<double>(band) - (kBandCount64 - 1u));
            const auto upper = band < kLinearBands ? band + 2u
                                                   : static_cast<uint32_t>(std::lround(exponential));
            edges[band + 1u] = static_cast<uint16_t>(std::max<uint32_t>(upper, edges[band] + 1u));
        }
    }

    ~AnalyzerResources()
    {
        if (fft != nullptr) vDSP_destroy_fftsetup(fft);
    }

};

AnalyzerResources& Resources()
{
    static AnalyzerResources resources;
    return resources;
}

float Level(float energy, float floor_db, float sensitivity)
{
    if (! (energy > 0.0f) || ! std::isfinite(energy)) {
        return 0.0f;
    }
    const float base = std::max(0.0f, 1.0f + (20.0f * std::log10(energy)) / floor_db);
    if (sensitivity == kAudioResponseDefaultSensitivity) {
        return base;
    }
    const float scaled = base * sensitivity;
    return std::isfinite(scaled) ? std::max(0.0f, scaled) : 0.0f;
}

struct ChannelLevels
{
    std::array<float, 64> bands64 {};
    std::array<float, 32> bands32 {};
    std::array<float, 16> bands16 {};
};

// Energy is summed over each bucket's bins, so a coarser resolution covers the
// same frequencies with the energy of the buckets it merges.
// Keep one out-of-line copy with 64-byte aligned FFT scratch buffers so mono
// and stereo paths dispatch the exact same vDSP kernel and codegen regardless
// of caller stack-frame alignment.
[[gnu::noinline]] ChannelLevels AnalyzeChannel(const float* pcm, float floor_db, float sensitivity)
{
    const auto& resources = Resources();

    alignas(64) std::array<float, kFftSize>      windowed {};
    alignas(64) std::array<float, kFftSize / 2u> realp {};
    alignas(64) std::array<float, kFftSize / 2u> imagp {};
    alignas(64) std::array<float, kFftSize / 2u> power {};

    vDSP_vmul(pcm, 1, resources.window.data(), 1, windowed.data(), 1,
              static_cast<vDSP_Length>(kWindowSize));
    // One NaN or infinity would spread through the whole transform.
    for (uint32_t index = 0; index < kWindowSize; ++index) {
        if (! std::isfinite(windowed[index])) windowed[index] = 0.0f;
    }

    // Real FFT input is packed as even samples in realp and odd samples in imagp.
    for (size_t index = 0; index < realp.size(); ++index) {
        realp[index] = windowed[index * 2u];
        imagp[index] = windowed[(index * 2u) + 1u];
    }
    DSPSplitComplex split { .realp = realp.data(), .imagp = imagp.data() };
    if (resources.fft == nullptr) {
        return {};
    }
    vDSP_fft_zrip(resources.fft, &split, 1, kFftLog2, kFFTDirection_Forward);
    // Slot 0 mixes DC with Nyquist; no bucket reads it.
    vDSP_zvmags(&split, 1, power.data(), 1, static_cast<vDSP_Length>(power.size()));

    std::array<float, kBandCount64> energy_squared {};
    for (uint32_t band = 0; band < kBandCount64; ++band) {
        float sum = 0.0f;
        for (uint32_t bin = resources.edges[band]; bin < resources.edges[band + 1u]; ++bin) {
            sum += power[bin];
        }
        energy_squared[band] = sum * resources.amplitude_scale * resources.amplitude_scale;
    }

    ChannelLevels levels;
    for (uint32_t band = 0; band < kBandCount64; ++band) {
        levels.bands64[band] = Level(std::sqrt(energy_squared[band]), floor_db, sensitivity);
    }
    for (uint32_t band = 0; band < 32u; ++band) {
        levels.bands32[band] =
            Level(std::sqrt(energy_squared[band * 2u] + energy_squared[band * 2u + 1u]), floor_db, sensitivity);
    }
    for (uint32_t band = 0; band < 16u; ++band) {
        float sum = 0.0f;
        for (uint32_t part = 0; part < 4u; ++part) sum += energy_squared[band * 4u + part];
        levels.bands16[band] = Level(std::sqrt(sum), floor_db, sensitivity);
    }
    return levels;
}

template<typename Array>
void SmoothInto(const Array& raw, Array& target, float smoothing)
{
    if (! (smoothing > 0.0f)) {
        target = raw;
        return;
    }
    const float raw_weight = 1.0f - smoothing;
    for (size_t band = 0; band < target.size(); ++band) {
        const float prev = (std::isfinite(target[band]) && target[band] > 0.0f) ? target[band] : 0.0f;
        const float blended = smoothing * prev + raw_weight * raw[band];
        target[band] = (raw[band] == 0.0f && blended < kSmoothingZeroFlush) ? 0.0f : blended;
    }
}

template<typename Array>
void Average(const Array& left, const Array& right, Array& average)
{
    for (size_t band = 0; band < average.size(); ++band) {
        average[band] = 0.5f * (left[band] + right[band]);
    }
}

} // namespace

AudioResponseTuning ClampAudioResponseTuning(AudioResponseTuning tuning)
{
    tuning.sensitivity = std::isfinite(tuning.sensitivity)
        ? std::clamp(tuning.sensitivity, kAudioResponseMinSensitivity, kAudioResponseMaxSensitivity)
        : kAudioResponseDefaultSensitivity;
    tuning.noise_floor_db = std::isfinite(tuning.noise_floor_db)
        ? std::clamp(tuning.noise_floor_db, kAudioResponseMinNoiseFloorDb, kAudioResponseMaxNoiseFloorDb)
        : kAudioResponseDefaultNoiseFloorDb;
    tuning.smoothing = std::isfinite(tuning.smoothing)
        ? std::clamp(tuning.smoothing, kAudioResponseMinSmoothing, kAudioResponseMaxSmoothing)
        : kAudioResponseDefaultSmoothing;
    return tuning;
}

void SetAudioResponseTuning(AudioResponseTuning tuning)
{
    const auto clamped = ClampAudioResponseTuning(tuning);
    g_tuning.sensitivity.store(clamped.sensitivity, std::memory_order_relaxed);
    g_tuning.noise_floor_db.store(clamped.noise_floor_db, std::memory_order_relaxed);
    g_tuning.smoothing.store(clamped.smoothing, std::memory_order_relaxed);
}

AudioResponseTuning CurrentAudioResponseTuning()
{
    return AudioResponseTuning {
        .sensitivity = g_tuning.sensitivity.load(std::memory_order_relaxed),
        .noise_floor_db = g_tuning.noise_floor_db.load(std::memory_order_relaxed),
        .smoothing = g_tuning.smoothing.load(std::memory_order_relaxed),
    };
}

void AnalyzeAudioResponseMonoBlock(
    const float* mono_pcm,
    uint32_t frame_count,
    AudioSpectrumSnapshot* snapshot)
{
    if (mono_pcm == nullptr || snapshot == nullptr || frame_count < kWindowSize) {
        return;
    }

    const auto tuning = CurrentAudioResponseTuning();
    const float floor_db = -tuning.noise_floor_db;
    const auto levels = AnalyzeChannel(mono_pcm, floor_db, tuning.sensitivity);
    SmoothInto(levels.bands64, snapshot->average64, tuning.smoothing);
    SmoothInto(levels.bands32, snapshot->average32, tuning.smoothing);
    SmoothInto(levels.bands16, snapshot->average16, tuning.smoothing);
    snapshot->left64 = snapshot->right64 = snapshot->average64;
    snapshot->left32 = snapshot->right32 = snapshot->average32;
    snapshot->left16 = snapshot->right16 = snapshot->average16;
    snapshot->stereo = false;
}

void AnalyzeAudioResponseStereoBlock(
    const float* left_pcm,
    const float* right_pcm,
    uint32_t frame_count,
    AudioSpectrumSnapshot* snapshot)
{
    if (left_pcm == nullptr || right_pcm == nullptr || snapshot == nullptr ||
        frame_count < kWindowSize) {
        return;
    }

    const auto tuning = CurrentAudioResponseTuning();
    const float floor_db = -tuning.noise_floor_db;
    const auto left = AnalyzeChannel(left_pcm, floor_db, tuning.sensitivity);
    const auto right = AnalyzeChannel(right_pcm, floor_db, tuning.sensitivity);
    SmoothInto(left.bands64, snapshot->left64, tuning.smoothing);
    SmoothInto(right.bands64, snapshot->right64, tuning.smoothing);
    SmoothInto(left.bands32, snapshot->left32, tuning.smoothing);
    SmoothInto(right.bands32, snapshot->right32, tuning.smoothing);
    SmoothInto(left.bands16, snapshot->left16, tuning.smoothing);
    SmoothInto(right.bands16, snapshot->right16, tuning.smoothing);
    Average(snapshot->left64, snapshot->right64, snapshot->average64);
    Average(snapshot->left32, snapshot->right32, snapshot->average32);
    Average(snapshot->left16, snapshot->right16, snapshot->average16);
    snapshot->stereo = true;
}

namespace
{
template<size_t N>
void Silence(std::array<float, N>& bands)
{
    std::fill(bands.begin(), bands.end(), 0.0f);
}
} // namespace

void ClearAudioResponseSnapshot(AudioSpectrumSnapshot* snapshot)
{
    if (snapshot == nullptr) return;
    // Only the levels go quiet; the counters and the stereo flag describe the stream.
    Silence(snapshot->left64);
    Silence(snapshot->right64);
    Silence(snapshot->average64);
    Silence(snapshot->left32);
    Silence(snapshot->right32);
    Silence(snapshot->average32);
    Silence(snapshot->left16);
    Silence(snapshot->right16);
    Silence(snapshot->average16);
}

} // namespace wallpaper::audio

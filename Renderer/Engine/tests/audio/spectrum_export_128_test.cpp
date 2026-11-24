// The 128-value spectrum export of the C binding (`owe_audio_current_spectrum_128`): left band
// levels in the first half, right in the second, each clamped to [0, 1], with the generation of
// the analysis they came from.
//
// The snapshot is not injectable, so the export is checked against the snapshot the public
// service publishes for audio the test submits itself.
#include "Platform/Apple/SceneWallpaperBindings.h"

#include "Audio/AudioResponseService.h"
#include "support/spectrum_wait.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <numbers>
#include <string>
#include <vector>

namespace wallpaper::audio
{
namespace
{

constexpr uint32_t kRate      = kAudioResponseSampleRate;
constexpr uint32_t kChunk     = 480;
constexpr float    kSentinel  = 7.0f;
constexpr double   kToneHertz = 1000.0;

class SpectrumExport128Test : public ::testing::Test {
protected:
    void SetUp() override { ResetAudioResponseServiceForTesting(); }
    void TearDown() override { ResetAudioResponseServiceForTesting(); }

    // `frames` frames of a sine at `amplitude`, interleaved L/R with each channel scaled as given.
    static std::vector<float> Tone(uint32_t frames, float left_amplitude, float right_amplitude)
    {
        std::vector<float> pcm(static_cast<size_t>(frames) * 2u);
        for (uint32_t frame = 0; frame < frames; ++frame) {
            const double phase =
                2.0 * std::numbers::pi * kToneHertz * static_cast<double>(frame) / kRate;
            const float s = static_cast<float>(std::sin(phase));
            pcm[frame * 2u]      = s * left_amplitude;
            pcm[frame * 2u + 1u] = s * right_amplitude;
        }
        return pcm;
    }

    // Feeds several analysis windows of stereo audio, in small chunks like a real tap.
    static void SubmitStereo(float left_amplitude, float right_amplitude)
    {
        const std::vector<float> pcm = Tone(kAudioResponseWindowFrames * 3u, left_amplitude,
                                            right_amplitude);
        const uint32_t           total = static_cast<uint32_t>(pcm.size() / 2u);
        for (uint32_t offset = 0; offset < total; offset += kChunk) {
            const uint32_t count = std::min(kChunk, total - offset);
            std::string    error;
            ASSERT_TRUE(SubmitAudioFrames(kRate, count, pcm.data() + offset * 2u, &error)) << error;
        }
    }

    struct Exported {
        std::array<float, 128> bins {};
        uint64_t               generation { 0 };
        int                    status { 0 };
    };

    static Exported Export()
    {
        Exported out;
        out.status = owe_audio_current_spectrum_128(out.bins.data(), out.bins.size(),
                                                    &out.generation);
        return out;
    }

    // An export and the snapshot of the very same analysis, retried while the worker publishes
    // between the two reads.
    static bool ExportWithSnapshot(Exported* exported, AudioSpectrumSnapshot* snapshot)
    {
        for (int attempt = 0; attempt < 200; ++attempt) {
            const AudioSpectrumSnapshot before = CurrentAudioSpectrumSnapshot();
            *exported                          = Export();
            const AudioSpectrumSnapshot after  = CurrentAudioSpectrumSnapshot();
            if (before.generation == after.generation &&
                exported->generation == after.generation && after.generation > 0u) {
                *snapshot = after;
                return true;
            }
        }
        return false;
    }
};

TEST_F(SpectrumExport128Test, ANullBufferIsRefusedWithAReason)
{
    uint64_t generation = 99;
    EXPECT_NE(owe_audio_current_spectrum_128(nullptr, 128, &generation), 0);
    const char* reason = owe_last_error();
    ASSERT_NE(reason, nullptr);
    EXPECT_NE(std::string(reason), "");
    EXPECT_EQ(generation, 99u) << "a refused call writes nothing";
}

TEST_F(SpectrumExport128Test, ABufferShorterThan128IsRefusedAndLeftUntouched)
{
    std::array<float, 128> bins;
    bins.fill(kSentinel);
    uint64_t generation = 99;
    EXPECT_NE(owe_audio_current_spectrum_128(bins.data(), 127, &generation), 0);
    EXPECT_EQ(generation, 99u);
    for (const float value : bins) EXPECT_EQ(value, kSentinel);
}

TEST_F(SpectrumExport128Test, ExactlyOneHundredTwentyEightIsAccepted)
{
    const Exported out = Export();
    EXPECT_EQ(out.status, 0);
}

TEST_F(SpectrumExport128Test, AServiceThatHasAnalysedNothingExportsSilenceAtGenerationZero)
{
    std::array<float, 128> bins;
    bins.fill(kSentinel);
    uint64_t generation = 99;
    ASSERT_EQ(owe_audio_current_spectrum_128(bins.data(), bins.size(), &generation), 0);
    EXPECT_EQ(generation, 0u);
    for (const float value : bins) EXPECT_EQ(value, 0.0f);
}

TEST_F(SpectrumExport128Test, TheGenerationOutputIsOptional)
{
    std::array<float, 128> bins {};
    EXPECT_EQ(owe_audio_current_spectrum_128(bins.data(), bins.size(), nullptr), 0);
}

TEST_F(SpectrumExport128Test, ALongerBufferKeepsItsExtraEntries)
{
    std::array<float, 140> bins;
    bins.fill(kSentinel);
    ASSERT_EQ(owe_audio_current_spectrum_128(bins.data(), bins.size(), nullptr), 0);
    for (size_t i = 0; i < 128; ++i) EXPECT_EQ(bins[i], 0.0f);
    for (size_t i = 128; i < bins.size(); ++i) EXPECT_EQ(bins[i], kSentinel);
}

TEST_F(SpectrumExport128Test, TheFirstHalfIsTheLeftChannelAndTheSecondHalfTheRight)
{
    // Only the left channel carries a tone: a swapped or shifted half would show up as energy
    // in the wrong half.
    SubmitStereo(0.5f, 0.0f);
    Exported              exported;
    AudioSpectrumSnapshot snapshot;
    ASSERT_TRUE(testing::PollSnapshot(std::chrono::milliseconds(1000), [](const auto& s) {
        return s.generation > 0u && s.left64 != std::array<float, 64> {};
    }).generation > 0u);
    ASSERT_TRUE(ExportWithSnapshot(&exported, &snapshot));
    ASSERT_EQ(exported.status, 0);

    float left_peak = 0.0f;
    for (size_t band = 0; band < 64; ++band) {
        left_peak = std::max(left_peak, exported.bins[band]);
        EXPECT_EQ(exported.bins[band], std::clamp(snapshot.left64[band], 0.0f, 1.0f));
        EXPECT_EQ(exported.bins[64 + band], std::clamp(snapshot.right64[band], 0.0f, 1.0f));
    }
    EXPECT_GT(left_peak, 0.1f) << "the left tone is visible in the first half";
    for (size_t band = 0; band < 64; ++band) {
        EXPECT_EQ(exported.bins[64 + band], 0.0f) << "silent right channel, band " << band;
    }
}

TEST_F(SpectrumExport128Test, LevelsAboveOneAreClampedToExactlyOne)
{
    // A tone far beyond full scale puts its band well over 1.0 in the snapshot.
    SubmitStereo(8.0f, 8.0f);
    Exported              exported;
    AudioSpectrumSnapshot snapshot;
    ASSERT_TRUE(testing::PollSnapshot(std::chrono::milliseconds(1000), [](const auto& s) {
        return s.generation > 0u && *std::max_element(s.left64.begin(), s.left64.end()) > 1.0f;
    }).generation > 0u);
    ASSERT_TRUE(ExportWithSnapshot(&exported, &snapshot));

    const float loudest_left  = *std::max_element(snapshot.left64.begin(), snapshot.left64.end());
    const float loudest_right = *std::max_element(snapshot.right64.begin(), snapshot.right64.end());
    ASSERT_GT(loudest_left, 1.0f) << "the snapshot itself exceeds 1 for this input";
    ASSERT_GT(loudest_right, 1.0f);
    EXPECT_EQ(*std::max_element(exported.bins.begin(), exported.bins.begin() + 64), 1.0f);
    EXPECT_EQ(*std::max_element(exported.bins.begin() + 64, exported.bins.end()), 1.0f);
    for (const float value : exported.bins) {
        EXPECT_GE(value, 0.0f);
        EXPECT_LE(value, 1.0f);
    }
}

TEST_F(SpectrumExport128Test, TheGenerationIsTheOneOfTheAnalysisTheLevelsCameFrom)
{
    SubmitStereo(0.5f, 0.5f);
    ASSERT_GT(testing::WaitForGeneration().generation, 0u);
    Exported              exported;
    AudioSpectrumSnapshot snapshot;
    ASSERT_TRUE(ExportWithSnapshot(&exported, &snapshot));
    EXPECT_GT(exported.generation, 0u);
    EXPECT_EQ(exported.generation, snapshot.generation);
}

TEST_F(SpectrumExport128Test, FullSpectrumExportAndSubmitRoundTripAllThreeResolutionsUnclamped)
{
    std::array<float, kAudioSpectrumFullBandCount> bands {};
    uint64_t                                       generation = 99;
    bool                                           stereo     = true;
    EXPECT_NE(owe_audio_current_spectrum_full(nullptr, bands.size(), &generation, &stereo), 0);
    EXPECT_NE(owe_audio_current_spectrum_full(bands.data(), bands.size() - 1u, &generation, &stereo), 0);
    EXPECT_NE(owe_audio_submit_spectrum_full(nullptr, bands.size(), true), 0);
    EXPECT_NE(owe_audio_submit_spectrum_full(bands.data(), bands.size() - 1u, true), 0);
    EXPECT_EQ(generation, 99u);

    SubmitStereo(8.0f, 0.25f);
    ASSERT_TRUE(testing::PollSnapshot(std::chrono::milliseconds(1000), [](const auto& s) {
        return s.generation > 0u && *std::max_element(s.left64.begin(), s.left64.end()) > 1.0f;
    }).generation > 0u);

    AudioSpectrumSnapshot original {};
    for (int attempt = 0; attempt < 200; ++attempt) {
        const AudioSpectrumSnapshot before = CurrentAudioSpectrumSnapshot();
        ASSERT_EQ(owe_audio_current_spectrum_full(bands.data(), bands.size(), &generation, &stereo), 0);
        const AudioSpectrumSnapshot after = CurrentAudioSpectrumSnapshot();
        if (before.generation == after.generation && generation == after.generation) {
            original = after;
            break;
        }
    }
    ASSERT_GT(original.generation, 0u);
    ASSERT_TRUE(stereo);
    EXPECT_GT(*std::max_element(bands.begin(), bands.begin() + 64), 1.0f)
        << "full scene export preserves levels above 1.0";

    // Reset and inject the exported snapshot as a sandboxed extension process would.
    ResetAudioResponseServiceForTesting();
    ASSERT_EQ(owe_audio_submit_spectrum_full(bands.data(), bands.size(), stereo), 0);
    const AudioSpectrumSnapshot replayed = CurrentAudioSpectrumSnapshot();
    EXPECT_EQ(replayed.generation, 1u);
    EXPECT_TRUE(replayed.stereo);
    EXPECT_EQ(owe_audio_spectrum_is_stereo(), 1);
    EXPECT_EQ(replayed.left64, original.left64);
    EXPECT_EQ(replayed.right64, original.right64);
    EXPECT_EQ(replayed.average64, original.average64);
    EXPECT_EQ(replayed.left32, original.left32);
    EXPECT_EQ(replayed.right32, original.right32);
    EXPECT_EQ(replayed.average32, original.average32);
    EXPECT_EQ(replayed.left16, original.left16);
    EXPECT_EQ(replayed.right16, original.right16);
    EXPECT_EQ(replayed.average16, original.average16);
}

TEST_F(SpectrumExport128Test, SubmittedFullSpectrumSanitizesMonoAndClearsWhenStale)
{
    std::array<float, kAudioSpectrumFullBandCount> bands {};
    bands[0]   = 1.35f;
    bands[1]   = -0.5f;
    bands[2]   = std::numeric_limits<float>::quiet_NaN();
    bands[3]   = std::numeric_limits<float>::infinity();
    bands[64]  = 0.9f; // ignored for mono
    bands[128] = 0.8f;
    bands[192] = 0.6f;

    ASSERT_EQ(owe_audio_submit_spectrum_full(bands.data(), bands.size(), false), 0);
    const AudioSpectrumSnapshot first = CurrentAudioSpectrumSnapshot();
    EXPECT_FALSE(first.stereo);
    EXPECT_EQ(owe_audio_spectrum_is_stereo(), 0);
    EXPECT_FLOAT_EQ(first.left64[0], 1.35f);
    EXPECT_FLOAT_EQ(first.right64[0], 1.35f);
    EXPECT_FLOAT_EQ(first.average64[0], 1.35f);
    EXPECT_FLOAT_EQ(first.left64[1], 0.0f);
    EXPECT_FLOAT_EQ(first.left64[2], 0.0f);
    EXPECT_FLOAT_EQ(first.left64[3], 0.0f);
    EXPECT_FLOAT_EQ(first.left32[0], 0.8f);
    EXPECT_FLOAT_EQ(first.right32[0], 0.8f);
    EXPECT_FLOAT_EQ(first.left16[0], 0.6f);
    EXPECT_FLOAT_EQ(first.right16[0], 0.6f);

    // Without further submissions, the 250 ms staleness rule clears the spectrum to silence.
    const AudioSpectrumSnapshot cleared = testing::PollSnapshot(
        std::chrono::milliseconds(1000),
        [gen = first.generation](const AudioSpectrumSnapshot& s) {
            return s.generation > gen && s.average64[0] == 0.0f && s.average32[0] == 0.0f &&
                   s.average16[0] == 0.0f;
        });
    EXPECT_GT(cleared.generation, first.generation);
    EXPECT_FLOAT_EQ(cleared.average64[0], 0.0f);
}

} // namespace
} // namespace wallpaper::audio

// The FFmpeg stream that remains: the audio track of a plain video wallpaper's
// file on disk (CreateMediaSoundStream). Scene sounds no longer reach FFmpeg;
// their tests are in sound_stream_test.cpp. These cases use small files the test
// writes to the temporary directory (never next to the repository).
#include "Audio/FfmpegSoundStream.hpp"
#include "Audio/SoundStreamFactory.hpp"
#include "audio/sound_test_support.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <unistd.h>

namespace wallpaper::audio
{
namespace
{

using namespace testing;

/// A file in the temporary directory, removed with the object.
class TempFile {
public:
    explicit TempFile(const std::vector<uint8_t>& bytes)
    {
        auto name = (std::filesystem::temp_directory_path() / "wallpaper-audio-XXXXXX").string();
        const int descriptor = mkstemp(name.data());
        EXPECT_GE(descriptor, 0);
        if (descriptor >= 0) close(descriptor);
        m_path = name;
        std::ofstream file(m_path, std::ios::binary);
        file.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    }
    ~TempFile()
    {
        std::error_code error;
        std::filesystem::remove(m_path, error);
    }
    TempFile(const TempFile&)            = delete;
    TempFile& operator=(const TempFile&) = delete;

    const std::filesystem::path& path() const { return m_path; }

private:
    std::filesystem::path m_path;
};

// A 1x1 PNG: a file FFmpeg recognises that has a video stream and no audio.
const std::vector<uint8_t> kPng {
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
    0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0x00, 0x02, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0d, 0x0a,
    0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82
};

TEST(FfmpegSoundStreamTest, AFileOnDiskDecodesLikeTheSameBytesAsASceneSound)
{
    const auto wav = MakeWav(WavFormat::Int16, 2, 44'100, 1500);
    TempFile   file(wav);
    std::string error;
    auto media = CreateMediaSoundStream(file.path(), &error, { .loop = false });
    ASSERT_NE(media, nullptr) << error;
    media->PassDesc({ 2, 48'000 });
    const auto from_file  = ReadAll(*media, { 2, 48'000 });
    const auto from_scene = Decode(wav, { 2, 48'000 });
    ASSERT_EQ(from_file.size(), from_scene.size());
    // Two resamplers: the same lengths and the same tone, not the same bits.
    for (size_t index = 200; index + 200 < from_file.size(); ++index) {
        ASSERT_NEAR(from_file[index], from_scene[index], 2e-3f) << index;
    }
}

TEST(FfmpegSoundStreamTest, ResampledTailPreservesTheAuthoredDuration)
{
    for (const auto [input_rate, output_rate, input_frames, expected_frames] :
         { std::array<uint32_t, 4> { 12'000, 48'000, 512, 2048 },
           std::array<uint32_t, 4> { 44'100, 48'000, 441, 480 },
           std::array<uint32_t, 4> { 48'000, 44'100, 480, 441 } }) {
        SCOPED_TRACE(input_rate);
        TempFile    file(MakeWav(WavFormat::Int16, 1, input_rate, input_frames));
        std::string error;
        auto sound = CreateMediaSoundStream(file.path(), &error, { .loop = false });
        ASSERT_NE(sound, nullptr) << error;
        sound->PassDesc({ 2, output_rate });
        EXPECT_EQ(ReadAll(*sound, { 2, output_rate }).size() / 2, expected_frames);
        std::array<float, 2 * 97> output {};
        output.fill(1.0f);
        EXPECT_EQ(sound->NextPcmData(output.data(), 97), 0u);
        EXPECT_TRUE(std::all_of(output.begin(), output.end(), [](float s) { return s == 0.0f; }));
    }
}

TEST(FfmpegSoundStreamTest, ALoopIncludesTheCompleteResampledTail)
{
    TempFile    file(MakeWav(WavFormat::Int16, 1, 12'000, 512));
    std::string error;
    auto once = CreateMediaSoundStream(file.path(), &error, { .loop = false });
    auto loop = CreateMediaSoundStream(file.path(), &error, { .loop = true });
    ASSERT_NE(once, nullptr) << error;
    ASSERT_NE(loop, nullptr) << error;
    once->PassDesc({ 2, 48'000 });
    loop->PassDesc({ 2, 48'000 });
    const auto pass = ReadAll(*once, { 2, 48'000 });
    ASSERT_EQ(pass.size(), 2u * 2048u);
    const auto cycles = ReadAll(*loop, { 2, 48'000 }, 97, 2048 * 3);
    ASSERT_GE(cycles.size(), pass.size() * 3);
    for (size_t index = 0; index < pass.size() * 3; ++index) {
        ASSERT_EQ(cycles[index], pass[index % pass.size()]) << index;
    }
}

TEST(FfmpegSoundStreamTest, AVideoWallpapersAudioLoopsByDefault)
{
    TempFile    file(MakeWav(WavFormat::Int16, 1, 12'000, 16));
    std::string error;
    auto sound = CreateMediaSoundStream(file.path(), &error);
    ASSERT_NE(sound, nullptr) << error;
    sound->PassDesc({ 1, 12'000 });
    EXPECT_GT(ReadAll(*sound, { 1, 12'000 }, 16, 160).size(), 16u * 4u);
}

TEST(FfmpegSoundStreamTest, AFileWithNoAudioIsSilentWhenAudioIsOptionalAndAnErrorOtherwise)
{
    TempFile    file(kPng);
    std::string error;
    EXPECT_EQ(CreateMediaSoundStream(file.path(), &error, {}, false), nullptr);
    EXPECT_FALSE(error.empty());

    error = "stale";
    EXPECT_EQ(CreateMediaSoundStream(file.path(), &error, {}, true), nullptr);
    EXPECT_TRUE(error.empty()) << error;
}

TEST(FfmpegSoundStreamTest, PathsThatAreNotAudioFilesFailWithAReason)
{
    std::string error;
    EXPECT_EQ(CreateMediaSoundStream("", &error), nullptr);
    EXPECT_FALSE(error.empty());
    error.clear();
    EXPECT_EQ(CreateMediaSoundStream("/nonexistent/wallpaper-audio-test.wav", &error, {}, true), nullptr);
    EXPECT_FALSE(error.empty()) << "a missing file is an error even when audio is optional";
    error.clear();
    EXPECT_EQ(CreateMediaSoundStream(std::filesystem::temp_directory_path(), &error), nullptr);
    EXPECT_FALSE(error.empty());
    TempFile garbage({ 1, 2, 3, 4 });
    error.clear();
    EXPECT_EQ(CreateMediaSoundStream(garbage.path(), &error), nullptr);
    EXPECT_FALSE(error.empty());
}

} // namespace
} // namespace wallpaper::audio

#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Shader/RustShaderBridge.hpp"
#include "WPShaderParser.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <filesystem>
#include <iterator>
#include <limits>
#include <fstream>
#include <string>
#include <span>
#include <string_view>
#include <vector>

#include <unistd.h>

namespace wallpaper
{
namespace
{

// The shader layer has one target, Metal, and the compile that settles a
// program's metadata is the compile that generates its stages. These tests look
// at what it merges into the units and the shader info; the stages are not
// their subject.
bool CompileProgram(std::string_view scene_id, std::string_view shader_name,
                    std::span<WPShaderUnit> units, fs::VFS& vfs, WPShaderInfo* shader_info,
                    std::span<const WPShaderTexInfo> textures,
                    std::string* reflection_json = nullptr)
{
    std::vector<shader::RustShaderMetalStage> stages;
    return WPShaderParser::CompileToMslRust(scene_id, shader_name, units, stages, vfs,
                                            shader_info, textures, reflection_json);
}

std::filesystem::path MakeTempDir() {
    // Per process: concurrent runs share the temporary directory, and this
    // folder is deleted before and after use.
    auto root = std::filesystem::temp_directory_path() /
                ("wpe-shader-cache-metadata-test-" + std::to_string(::getpid()));
    std::error_code ec;
    std::filesystem::remove_all(root, ec);
    std::filesystem::create_directories(root / "cache", ec);
    std::filesystem::create_directories(root / "assets", ec);
    return root;
}

std::array<WPShaderUnit, 2> MakeShaderUnits() {
    return {
        WPShaderUnit {
            .stage           = ShaderType::VERTEX,
            .src             = R"(
in vec3 a_Position;
out vec2 v_TexCoord;
void main() {
    v_TexCoord = vec2(0.5, 0.5);
    gl_Position = vec4(a_Position, 1.0);
}
)",
            .preprocess_info = {},
        },
        WPShaderUnit {
            .stage           = ShaderType::FRAGMENT,
            .src             = R"(
in vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)",
            .preprocess_info = {},
        },
    };
}

TEST(ShaderCacheMetadataTest, CacheHitStillPopulatesActiveTextureSlots) {
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    const auto temp = MakeTempDir();
    struct RemoveOnExit {
        std::filesystem::path path;
        ~RemoveOnExit() {
            std::error_code ec;
            std::filesystem::remove_all(path, ec);
        }
    } remove_on_exit { temp };
    WPShaderParser::ClearProgramCache();
    WPShaderParser::ResetStartupMetrics();

    fs::VFS vfs;
    ASSERT_TRUE(
        vfs.Mount("/cache", fs::CreatePhysicalFs((temp / "cache").string(), true), "cache"));
    ASSERT_TRUE(
        vfs.Mount("/assets", fs::CreatePhysicalFs((temp / "assets").string(), true), "assets"));

    std::vector<WPShaderTexInfo> textures { WPShaderTexInfo { .enabled = true } };

    {
        WPShaderInfo info;
        auto         units = MakeShaderUnits();
        ASSERT_TRUE(CompileProgram(
            "demo-scene", "tests/cache-metadata", units, vfs, &info, textures))
            << shader::LastRustShaderError();
        ASSERT_TRUE(units[1].preprocess_info.active_tex_slots.contains(0));
        const auto cache_root = temp / "cache" / "demo-scene" / "programs01";
        ASSERT_TRUE(std::filesystem::is_directory(cache_root));
        // One entry, and nothing else: the shader cache is the program JSON alone.
        EXPECT_EQ(std::distance(std::filesystem::directory_iterator(temp / "cache" / "demo-scene"),
                                std::filesystem::directory_iterator {}),
                  1);
        EXPECT_EQ(WPShaderParser::GetStartupMetrics().cache_misses, 1u);
    }

    // A disk hit, not just a same-process hit, must restore reflection as well.
    WPShaderParser::ClearProgramCache();
    {
        WPShaderInfo info;
        auto         units = MakeShaderUnits();
        ASSERT_TRUE(CompileProgram(
            "demo-scene", "tests/cache-metadata", units, vfs, &info, textures))
            << shader::LastRustShaderError();
        ASSERT_TRUE(units[1].preprocess_info.active_tex_slots.contains(0));
        EXPECT_EQ(WPShaderParser::GetStartupMetrics().cache_hits, 1u);
    }

    auto compile = [&] {
        WPShaderInfo info;
        auto units = MakeShaderUnits();
        units[1].src = "#include \"tint.h\"\n" + units[1].src;
        std::string reflection;
        EXPECT_TRUE(CompileProgram(
            "demo-scene", "tests/cache-includes", units, vfs, &info, textures, &reflection));
        EXPECT_FALSE(reflection.empty());
        EXPECT_TRUE(units[1].preprocess_info.active_tex_slots.contains(0));
    };
    std::filesystem::create_directories(temp / "assets/shaders");
    std::ofstream(temp / "assets/shaders/tint.h") << "// first include\n";
    compile();
    auto misses = WPShaderParser::GetStartupMetrics().cache_misses;
    compile();
    EXPECT_EQ(WPShaderParser::GetStartupMetrics().cache_misses, misses);
    std::ofstream(temp / "assets/shaders/tint.h") << "// changed include\n";
    compile();
    EXPECT_EQ(WPShaderParser::GetStartupMetrics().cache_misses, ++misses);

    // A truncated persisted entry must trigger recompilation, not break loading.
    WPShaderParser::ClearProgramCache();
    for (const auto& entry : std::filesystem::directory_iterator(temp / "cache/demo-scene/programs01")) {
        std::ofstream(entry.path()) << "{";
    }
    compile();
    EXPECT_EQ(WPShaderParser::GetStartupMetrics().cache_misses, ++misses);
#endif
}

} // namespace
} // namespace wallpaper

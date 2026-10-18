#include "WPShaderParser.hpp"

#include "Fs/IBinaryStream.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Shader/RustShaderBridge.hpp"
#include "Utils/Logging.h"
#include "Utils/Sha.hpp"
#include <unordered_map>

#include <chrono>
#include <cstdint>
#include <unistd.h>
#include <optional>
#include <string>

using namespace wallpaper;

namespace
{

// Re-encodes a compiled Metal stage into the same payload shape the Rust
// bridge returns, so cached programs restore through one parser.
nlohmann::json MetalStageMetaJson(const wallpaper::shader::RustShaderMetalStage& stage) {
    auto bindings = nlohmann::json::array();
    for (const auto& binding : stage.bindings) {
        const char* slot_kind = "buffer";
        switch (binding.slot_kind) {
        case wallpaper::shader::RustShaderMetalSlotKind::Buffer: slot_kind = "buffer"; break;
        case wallpaper::shader::RustShaderMetalSlotKind::Texture: slot_kind = "texture"; break;
        case wallpaper::shader::RustShaderMetalSlotKind::Sampler: slot_kind = "sampler"; break;
        }
        bindings.push_back({
            {"name", binding.name},
            {"set", binding.set},
            {"binding", binding.binding},
            {"slot_kind", slot_kind},
            {"slot", binding.slot},
        });
    }

    return {
        {"entry_point", stage.entry_point},
        {"language_version", stage.language_version},
        {"bindings", std::move(bindings)},
        {"conventions",
         {
             {"clip_space_y_flipped", stage.conventions.clip_space_y_flipped},
             {"clip_space_depth_remapped", stage.conventions.clip_space_depth_remapped},
             {"texture_origin_flipped", stage.conventions.texture_origin_flipped},
         }},
    };
}

} // namespace

void WPShaderParser::BeginShaderSession() {
    // CLEANROOM LT19
}
void WPShaderParser::EndShaderSession() {
    // CLEANROOM LT20
}

void WPShaderParser::ResetStartupMetrics() {
    // CLEANROOM LT21
}
ShaderStartupMetrics WPShaderParser::GetStartupMetrics() {
    // CLEANROOM LT22
    return {};
}
void WPShaderParser::ClearProgramCache() {
    // CLEANROOM LT23
}

namespace
{

// Where one compile reads its includes from and what it is allowed to cache.
//
// A parse has the project mounted and caches to it. A variant compiled later
// has neither: it replays the includes the ordinary translation of the same
// program recorded, and writes nothing. Both go through the identical compile
// below, so the second is not a different translation with different rules.
// The one compile path of the Rust shader layer, which has a single target
// (Metal Shading Language): include resolution, combo defaults, program caching,
// metadata and reflection, and the compiled stages.
struct RustCompileEnv {
    fs::VFS*                  vfs { nullptr };
    const WPShaderIncludeMap* includes { nullptr };
    WPShaderIncludeMap*       used_includes { nullptr };
};

bool CompileProgramRust(std::string_view scene_id, std::string_view shader_name,
                        std::span<WPShaderUnit> units,
                        wallpaper::shader::RustShaderOutput& output, const RustCompileEnv& env,
                        WPShaderInfo* shader_info, std::span<const WPShaderTexInfo> texs,
                        std::string* reflection_json,
                        std::optional<uint32_t> nv12_plane_slot = std::nullopt) {
    // CLEANROOM LT24
    (void)scene_id;
    (void)shader_name;
    (void)units;
    (void)output;
    (void)env;
    (void)shader_info;
    (void)texs;
    (void)reflection_json;
    (void)nv12_plane_slot;
    return false;
}

} // namespace

bool WPShaderParser::CompileToMslRust(std::string_view scene_id, std::string_view shader_name,
                                      std::span<WPShaderUnit> units,
                                      std::vector<wallpaper::shader::RustShaderMetalStage>& stages,
                                      fs::VFS& vfs, WPShaderInfo* shader_info,
                                      std::span<const WPShaderTexInfo> texs,
                                      std::string* reflection_json,
                                      std::optional<uint32_t> nv12_plane_slot,
                                      WPShaderIncludeMap* used_includes) {
    shader::RustShaderOutput output {};
    const RustCompileEnv env { .vfs = &vfs, .used_includes = used_includes };
    if (! CompileProgramRust(scene_id, shader_name, units, output, env,
                             shader_info, texs, reflection_json, nv12_plane_slot)) {
        return false;
    }
    if (output.metal_stages.size() != units.size()) {
        LOG_ERROR("Rust shader returned %zu metal stages for %zu units in '%s'",
                  output.metal_stages.size(), units.size(), std::string(shader_name).c_str());
        return false;
    }

    stages = std::move(output.metal_stages);
    return true;
}

bool WPShaderParser::CompileMslVariant(const SceneMetalVariantInputs&             inputs,
                                       std::string_view                           cache_root,
                                       std::vector<wallpaper::shader::RustShaderMetalStage>& stages,
                                       std::string* reflection_json, std::string* error) {
    // Copies of the caller's snapshot, never the snapshot itself: this compile
    // merges its own combos, default textures and preprocessor results into
    // whatever it is handed, and the snapshot has to stay exactly as captured
    // so a second attempt -- after a failure, or for another surface -- starts
    // from the same place.
    auto         units       = inputs.units;
    WPShaderInfo shader_info = inputs.shader_info;

    // The same on-disk program cache the ordinary translation writes, reached
    // without the parse's virtual file system because that is long gone by the
    // time anything asks for a variant. Only `/cache` is mounted: the includes
    // come from the snapshot, so nothing here can read the project, and the
    // cache key is built from the request exactly as it is during a parse --
    // which is why an entry written by one launch is found by the next.
    //
    // An absent or unusable cache root is not a failure. It compiles, and the
    // result lives for as long as this process does.
    fs::VFS cache_vfs;
    if (! cache_root.empty()) {
        if (! cache_vfs.Mount("/cache", fs::CreatePhysicalFs(cache_root, true), "cache")) {
            LOG_INFO("metal variant cache folder unavailable: %s",
                     std::string(cache_root).c_str());
        }
    }

    shader::RustShaderOutput output {};
    const RustCompileEnv env { .vfs      = cache_vfs.IsMounted("cache") ? &cache_vfs : nullptr,
                               .includes = &inputs.includes };
    const auto           set_error = [error](std::string message) {
        if (error != nullptr) *error = std::move(message);
        return false;
    };

    try {
        if (! CompileProgramRust(inputs.scene_id, inputs.shader_name, units, output, env,
                                 &shader_info, inputs.texinfos, reflection_json,
                                 inputs.nv12_plane_slot)) {
            auto message = wallpaper::shader::LastRustShaderError();
            if (message.empty()) message = "the shader cannot sample the video as planes";
            return set_error(std::move(message));
        }
    } catch (const std::exception& e) {
        return set_error(e.what());
    }
    if (output.metal_stages.size() != units.size()) {
        return set_error("the plane variant produced the wrong number of stages");
    }

    stages = std::move(output.metal_stages);
    return true;
}

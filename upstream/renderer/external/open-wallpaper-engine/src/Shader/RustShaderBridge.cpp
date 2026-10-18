#include "Shader/RustShaderBridge.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

namespace wallpaper::shader
{
namespace
{


struct RsShaderOwnedBytes {
    uint8_t* ptr;
    size_t   len;
    void (*free)(uint8_t*, size_t, void*);
    void* free_user_data;
};

struct RsShaderProgram;

using RsShaderIncludeCallback = RsShaderOwnedBytes (*)(const char*, void*);

#ifdef WESCENE_HAS_RUST_SHADER_FFI
extern "C"
{
int rs_shader_compile_program(
    const char* request_json,
    RsShaderIncludeCallback include_callback,
    void* include_user_data,
    RsShaderProgram** out_program);
size_t rs_shader_program_stage_count(const RsShaderProgram* program);
int rs_shader_program_stage_kind(const RsShaderProgram* program, size_t stage_index);
int rs_shader_program_stage_target(const RsShaderProgram* program, size_t stage_index);
const char* rs_shader_program_stage_msl_source(
    const RsShaderProgram* program,
    size_t stage_index);
const char* rs_shader_program_stage_metal_json(
    const RsShaderProgram* program,
    size_t stage_index);
const char* rs_shader_program_metadata_json(const RsShaderProgram* program);
const char* rs_shader_program_reflection_json(const RsShaderProgram* program);
const char* rs_shader_program_diagnostics_json(const RsShaderProgram* program);
const char* rs_shader_program_cache_key(const RsShaderProgram* program);
void rs_shader_program_free(RsShaderProgram* program);
const char* rs_shader_last_error();
const char* rs_shader_cache_identity();
}
#endif

RustShaderMetalSlotKind FromMetalSlotKind(std::string_view slot_kind)
{
    if (slot_kind == "buffer") {
        return RustShaderMetalSlotKind::Buffer;
    }
    if (slot_kind == "texture") {
        return RustShaderMetalSlotKind::Texture;
    }
    if (slot_kind == "sampler") {
        return RustShaderMetalSlotKind::Sampler;
    }
    throw std::runtime_error("Rust shader returned an unknown metal slot kind");
}

} // namespace

nlohmann::json BuildRustShaderRequestJson(const RustShaderRequest& request)
{
    // CLEANROOM PH15
    (void)request;
    return nlohmann::json::object();
}

void ApplyRustShaderMetadataJson(std::string_view metadata_json, RustShaderOutput& output)
{
    // CLEANROOM PH16
    (void)metadata_json, (void)output;
}

void ApplyRustShaderReflectionJson(std::string_view reflection_json, RustShaderOutput& output)
{
    // CLEANROOM PH17
    (void)reflection_json, (void)output;
}

void ApplyRustShaderMetalStageJson(
    std::string_view metal_json,
    std::string_view msl_source,
    ShaderType kind,
    RustShaderMetalStage& stage)
{
    const auto metal = nlohmann::json::parse(metal_json);

    stage.kind        = kind;
    stage.source      = std::string(msl_source);
    stage.entry_point = metal.at("entry_point").get<std::string>();
    if (stage.entry_point.empty()) {
        throw std::runtime_error("Rust shader returned an empty metal entry point");
    }
    stage.language_version = metal.value("language_version", std::string {});

    stage.bindings.clear();
    for (const auto& binding : metal.value("bindings", nlohmann::json::array())) {
        stage.bindings.push_back(RustShaderMetalBinding {
            .name      = binding.at("name").get<std::string>(),
            .set       = binding.at("set").get<uint32_t>(),
            .binding   = binding.at("binding").get<uint32_t>(),
            .slot_kind = FromMetalSlotKind(binding.at("slot_kind").get<std::string>()),
            .slot      = binding.at("slot").get<uint32_t>(),
        });
    }

    const auto conventions = metal.value("conventions", nlohmann::json::object());
    stage.conventions      = RustShaderMetalConventions {
             .clip_space_y_flipped      = conventions.value("clip_space_y_flipped", false),
             .clip_space_depth_remapped = conventions.value("clip_space_depth_remapped", false),
             .texture_origin_flipped    = conventions.value("texture_origin_flipped", false),
    };
}

bool CompileRustShaderProgram(
    const RustShaderRequest& request,
    RustShaderOutput& output,
    const RustShaderIncludeReader& include_reader)
{
    // CLEANROOM PH18
    (void)request, (void)include_reader;
    output = RustShaderOutput {};
    return false;
}

std::string RustShaderCacheIdentity()
{
    // CLEANROOM PH19
    return std::string {};
}

std::string LastRustShaderError()
{
    // CLEANROOM PH20
    return std::string {};
}

#ifdef WESCENE_BUILD_TESTS
bool CompileRustShaderProgramWithBridgeJson(
    const nlohmann::json& request_json,
    RustShaderOutput& output,
    const RustShaderIncludeReader& include_reader)
{
    // CLEANROOM PH21
    (void)request_json, (void)include_reader;
    output = RustShaderOutput {};
    return false;
}
#endif

} // namespace wallpaper::shader

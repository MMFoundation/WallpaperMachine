// Clean-room implementation from the WallpaperMachine spec e6-platform-host-api.md; written without access to the original source.
#include "Shader/RustShaderBridge.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <memory>
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

const char* StageKindName(ShaderType kind)
{
    switch (kind) {
    case ShaderType::VERTEX: return "vertex";
    case ShaderType::FRAGMENT: return "fragment";
    default: break;
    }
    throw std::runtime_error("shader stage kind must be vertex or fragment");
}

ShaderValue ShaderValueFromDefault(const nlohmann::json& value)
{
    const auto& kind = value.at("kind").get_ref<const std::string&>();
    const auto& body = value.at("value");
    if (kind == "number") return ShaderValue(body.get<float>());
    if (kind == "bool") return ShaderValue(body.get<bool>() ? 1.0f : 0.0f);
    if (kind == "vec2" || kind == "vec3" || kind == "vec4" || kind == "matrix4") {
        const auto floats = body.get<std::vector<float>>();
        return ShaderValue(floats.data(), floats.size());
    }
    return ShaderValue {};
}

void MergeActiveSlots(const nlohmann::json& document, RustShaderOutput& output)
{
    const auto slots = document.value("active_texture_slots", nlohmann::json::array());
    for (const auto& slot : slots) {
        output.fragment_preprocessor_info.active_tex_slots.insert(slot.get<uint>());
    }
}

#ifdef WESCENE_HAS_RUST_SHADER_FFI
struct ProgramRelease {
    void operator()(RsShaderProgram* program) const noexcept { rs_shader_program_free(program); }
};
using ProgramHandle = std::unique_ptr<RsShaderProgram, ProgramRelease>;

void ReleaseIncludeBytes(uint8_t* ptr, size_t, void*)
{
    std::free(ptr);
}

RsShaderOwnedBytes ServeInclude(const char* path, void* user_data)
{
    const RsShaderOwnedBytes none { nullptr, 0, nullptr, nullptr };
    const auto* reader = static_cast<const RustShaderIncludeReader*>(user_data);
    if (path == nullptr || reader == nullptr || ! *reader) return none;
    try {
        const std::optional<std::string> found = (*reader)(path);
        if (! found.has_value()) return none;
        // An empty include is not a missing one: hand back a non-null pointer.
        auto* bytes = static_cast<uint8_t*>(std::malloc(std::max<size_t>(found->size(), 1)));
        if (bytes == nullptr) return none;
        if (! found->empty()) std::memcpy(bytes, found->data(), found->size());
        return RsShaderOwnedBytes { bytes, found->size(), &ReleaseIncludeBytes, nullptr };
    } catch (...) {
        return none;
    }
}

std::string Borrowed(const char* text)
{
    return text != nullptr ? std::string(text) : std::string {};
}

bool CompileRequestText(const std::string& request_text,
                        RustShaderOutput& output,
                        const RustShaderIncludeReader& include_reader)
{
    output = RustShaderOutput {};
    RsShaderProgram* raw = nullptr;
    const int status = rs_shader_compile_program(request_text.c_str(),
                                                 include_reader ? &ServeInclude : nullptr,
                                                 const_cast<RustShaderIncludeReader*>(&include_reader),
                                                 &raw);
    ProgramHandle program(raw);
    if (status != 0 || ! program) return false;

    try {
        RustShaderOutput built;
        const size_t stage_count = rs_shader_program_stage_count(program.get());
        for (size_t i = 0; i < stage_count; ++i) {
            const int kind = rs_shader_program_stage_kind(program.get(), i);
            if (kind != 0 && kind != 1) return false;
            if (rs_shader_program_stage_target(program.get(), i) != 1) return false;
            const std::string msl = Borrowed(rs_shader_program_stage_msl_source(program.get(), i));
            if (msl.empty()) return false;
            const std::string metal_json =
                Borrowed(rs_shader_program_stage_metal_json(program.get(), i));
            RustShaderMetalStage stage;
            ApplyRustShaderMetalStageJson(
                metal_json, msl, kind == 0 ? ShaderType::VERTEX : ShaderType::FRAGMENT, stage);
            built.metal_stages.push_back(std::move(stage));
        }
        built.metadata_json    = Borrowed(rs_shader_program_metadata_json(program.get()));
        built.reflection_json  = Borrowed(rs_shader_program_reflection_json(program.get()));
        built.diagnostics_json = Borrowed(rs_shader_program_diagnostics_json(program.get()));
        built.cache_key        = Borrowed(rs_shader_program_cache_key(program.get()));
        ApplyRustShaderMetadataJson(built.metadata_json, built);
        ApplyRustShaderReflectionJson(built.reflection_json, built);
        output = std::move(built);
        return true;
    } catch (...) {
        output = RustShaderOutput {};
        return false;
    }
}
#endif

} // namespace

nlohmann::json BuildRustShaderRequestJson(const RustShaderRequest& request)
{
    using nlohmann::json;
    json document = json::object();
    document["shader_name"] = request.shader_name;
    document["target"]      = "metal_msl";
    if (request.cache_enabled) {
        document["cache_policy"] = { { "mode", "enabled" }, { "scene_id", request.scene_id } };
    } else {
        document["cache_policy"] = { { "mode", "disabled" } };
    }

    json stages = json::array();
    for (const auto& stage : request.stages) {
        stages.push_back({ { "kind", StageKindName(stage.kind) }, { "source", stage.source } });
    }
    document["stages"] = std::move(stages);

    json combos = json::array();
    for (const auto& [name, value] : request.combos) {
        combos.push_back({ { "name", name }, { "value", value } });
    }
    document["combos"] = std::move(combos);

    json textures = json::array();
    for (const auto& texture : request.textures) {
        json entry = {
            { "slot", texture.slot },
            { "present", texture.present },
            { "enabled", texture.enabled },
            { "format", texture.format },
            { "components",
              { { "compo1", texture.components[0] },
                { "compo2", texture.components[1] },
                { "compo3", texture.components[2] },
                { "compo4", texture.components[3] } } },
        };
        if (texture.video_planes == RustShaderVideoPlanes::Nv12Biplanar) {
            entry["video_planes"] = "nv12_biplanar";
        }
        textures.push_back(std::move(entry));
    }
    document["textures"] = std::move(textures);

    json properties = json::array();
    for (const auto& property : request.properties) {
        properties.push_back({ { "name", property.name },
                               { "value",
                                 { { "kind", property.value.kind },
                                   { "value", property.value.value } } } });
    }
    document["properties"] = std::move(properties);
    return document;
}

void ApplyRustShaderMetadataJson(std::string_view metadata_json, RustShaderOutput& output)
{
    const auto document = nlohmann::json::parse(metadata_json);
    const auto& none    = nlohmann::json::array();
    // Decode everything first so a malformed element leaves the output as it was.
    Combos                                combos;
    WPAliasValueDict                      aliases;
    ShaderValueMap                        uniforms;
    WPDefaultTexs                         textures;
    for (const auto& entry : document.value("combos", none)) {
        combos[entry.at("name").get<std::string>()] = entry.at("value").get<std::string>();
    }
    for (const auto& entry : document.value("aliases", none)) {
        aliases[entry.at("material").get<std::string>()] = entry.at("uniform").get<std::string>();
    }
    for (const auto& entry : document.value("default_uniforms", none)) {
        uniforms.insert_or_assign(entry.at("name").get<std::string>(),
                                  ShaderValueFromDefault(entry.at("value")));
    }
    for (const auto& entry : document.value("default_textures", none)) {
        textures.emplace_back(entry.at("slot").get<i32>(), entry.at("path").get<std::string>());
    }
    std::vector<uint> slots;
    for (const auto& slot : document.value("active_texture_slots", none)) {
        slots.push_back(slot.get<uint>());
    }

    auto& info = output.shader_info;
    for (auto& [k, v] : combos) info.combos[k] = std::move(v);
    for (auto& [k, v] : aliases) info.alias[k] = std::move(v);
    for (auto& [k, v] : uniforms) info.svs.insert_or_assign(k, std::move(v));
    for (auto& t : textures) info.defTexs.push_back(std::move(t));
    output.fragment_preprocessor_info.active_tex_slots.insert(slots.begin(), slots.end());
}

void ApplyRustShaderReflectionJson(std::string_view reflection_json, RustShaderOutput& output)
{
    MergeActiveSlots(nlohmann::json::parse(reflection_json), output);
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
#ifdef WESCENE_HAS_RUST_SHADER_FFI
    try {
        return CompileRequestText(BuildRustShaderRequestJson(request).dump(), output, include_reader);
    } catch (...) {
        output = RustShaderOutput {};
        return false;
    }
#else
    (void)request, (void)include_reader;
    output = RustShaderOutput {};
    return false;
#endif
}

std::string RustShaderCacheIdentity()
{
#ifdef WESCENE_HAS_RUST_SHADER_FFI
    return Borrowed(rs_shader_cache_identity());
#else
    return "wallpaper-machine-shader-compiler-not-linked";
#endif
}

std::string LastRustShaderError()
{
#ifdef WESCENE_HAS_RUST_SHADER_FFI
    return Borrowed(rs_shader_last_error());
#else
    return "the shader compiler is not linked into this build";
#endif
}

#ifdef WESCENE_BUILD_TESTS
bool CompileRustShaderProgramWithBridgeJson(
    const nlohmann::json& request_json,
    RustShaderOutput& output,
    const RustShaderIncludeReader& include_reader)
{
#ifdef WESCENE_HAS_RUST_SHADER_FFI
    try {
        return CompileRequestText(request_json.dump(), output, include_reader);
    } catch (...) {
        output = RustShaderOutput {};
        return false;
    }
#else
    (void)request_json, (void)include_reader;
    output = RustShaderOutput {};
    return false;
#endif
}
#endif

} // namespace wallpaper::shader

#include "Shader/RustShaderBridge.hpp"

#include "Fs/VFS.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <set>
#include <stdexcept>

using wallpaper::ShaderType;
using wallpaper::shader::RustShaderRequest;
using wallpaper::shader::RustShaderStageSource;
using wallpaper::shader::RustShaderTextureInfo;

namespace
{

/// The names of the descriptors the reflection payload of a compile reports.
std::set<std::string> DescriptorNames(const wallpaper::shader::RustShaderOutput& output)
{
    std::set<std::string> names;
    const auto reflection = nlohmann::json::parse(output.reflection_json);
    for (const auto& descriptor : reflection.value("descriptor_bindings", nlohmann::json::array())) {
        names.insert(descriptor.value("name", std::string {}));
    }
    return names;
}

RustShaderRequest TinyRequest()
{
    RustShaderRequest request;
    request.shader_name   = "bridge/tiny";
    request.scene_id      = "3611439897";
    request.cache_enabled = true;
    request.stages = {
        RustShaderStageSource {
            .kind   = ShaderType::VERTEX,
            .source = "attribute vec2 a_Position;\n"
                      "void main() { gl_Position = vec4(a_Position, 0.0, 1.0); }\n",
        },
        RustShaderStageSource {
            .kind   = ShaderType::FRAGMENT,
            .source = "void main() { gl_FragColor = vec4(1.0); }\n",
        },
    };
    request.combos["BLENDMODE"] = "0";
    request.textures.push_back(RustShaderTextureInfo {
        .slot       = 0,
        .present    = true,
        .enabled    = true,
        .format     = "rgba8",
        .components = { true, false, false },
    });
    return request;
}

std::array<wallpaper::WPShaderUnit, 2> ParserBridgeUnits()
{
    return {
        wallpaper::WPShaderUnit {
            .stage           = ShaderType::VERTEX,
            .src             = "attribute vec2 a_Position;\n"
                               "varying vec2 v_Uv;\n"
                               "void main() {\n"
                               "  v_Uv = a_Position * 0.5 + vec2(0.5);\n"
                               "  gl_Position = vec4(a_Position, 0.0, 1.0);\n"
                               "}\n",
            .preprocess_info = {},
        },
        wallpaper::WPShaderUnit {
            .stage           = ShaderType::FRAGMENT,
            .src             = "varying vec2 v_Uv;\n"
                               "uniform sampler2D g_Texture0; // {\"material\":\"albedo\",\"combo\":\"HAS_TEXTURE\",\"default\":\"materials/default.png\"}\n"
                               "uniform float g_Brightness; // {\"material\":\"brightness\",\"default\":1.25}\n"
                               "void main() {\n"
                               "  gl_FragColor = texture2D(g_Texture0, v_Uv) * g_Brightness;\n"
                               "}\n",
            .preprocess_info = {},
        },
    };
}

nlohmann::json RequestJsonWithInclude(std::string include_path)
{
    auto json = wallpaper::shader::BuildRustShaderRequestJson(TinyRequest());
    json["stages"][0]["source"] =
        "#include \"" + include_path + "\"\n"
        "attribute vec2 a_Position;\n"
        "void main() { gl_Position = vec4(a_Position, 0.0, 1.0); }\n";
    return json;
}

} // namespace

TEST(RustShaderBridge, BuildsSerdeTaggedRequestJsonWithEnabledCachePolicy)
{
    const auto json = wallpaper::shader::BuildRustShaderRequestJson(TinyRequest());

    ASSERT_EQ(json.at("shader_name"), "bridge/tiny");
    ASSERT_EQ(json.at("target"), "analysis");
    ASSERT_EQ(json.at("cache_policy"), (nlohmann::json {
                                             { "mode", "enabled" },
                                             { "scene_id", "3611439897" },
                                         }));
    ASSERT_EQ(json.at("stages").at(0).at("kind"), "vertex");
    ASSERT_EQ(json.at("stages").at(1).at("kind"), "fragment");
    ASSERT_EQ(json.at("combos").at(0), (nlohmann::json {
                                            { "name", "BLENDMODE" },
                                            { "value", "0" },
                                        }));
    ASSERT_TRUE(json.at("textures").at(0).at("present"));
    ASSERT_EQ(json.at("textures").at(0).at("components"), (nlohmann::json {
                                                               { "compo1", true },
                                                               { "compo2", false },
                                                               { "compo3", false },
                                                               { "compo4", false },
                                                           }));
    ASSERT_TRUE(json.at("properties").is_array());
}

TEST(RustShaderBridge, ParsesMetadataAndTheActiveSlotsOfAReflection)
{
    wallpaper::shader::RustShaderOutput output;

    wallpaper::shader::ApplyRustShaderMetadataJson(
        R"({
            "combos":[{"name":"HASALPHA","value":"1"}],
            "aliases":[{"material":"strength","uniform":"g_Strength"}],
            "default_uniforms":[{"name":"g_Strength","value":{"kind":"number","value":0.75}}],
            "default_textures":[{"slot":0,"path":"materials/default.png"}],
            "active_texture_slots":[0,2]
        })",
        output);
    wallpaper::shader::ApplyRustShaderReflectionJson(
        R"({
            "descriptor_bindings":[{
                "name":"GlobalUniforms",
                "set":0,
                "binding":0,
                "descriptor":"uniform_buffer",
                "stages":["vertex","fragment"],
                "count":1
            },{
                "name":"g_Texture0",
                "set":0,
                "binding":1,
                "descriptor":"sampled_image",
                "stages":["fragment"],
                "count":1
            },{
                "name":"_we_Sampler_g_Texture0",
                "set":0,
                "binding":2,
                "descriptor":"sampler",
                "stages":["fragment"],
                "count":1
            }],
            "uniform_blocks":[{
                "name":"GlobalUniforms",
                "set":0,
                "binding":0,
                "size":64,
                "members":[{
                    "name":"g_ModelViewProjectionMatrix",
                    "offset":0,
                    "size":64,
                    "element_count":16,
                    "array_count":0,
                    "array_stride":0
                }]
            }],
            "vertex_inputs":[{"name":"a_Position","location":0,"format":"r32g32_sfloat"}],
            "active_texture_slots":[0]
        })",
        output);

    ASSERT_EQ(output.shader_info.combos.at("HASALPHA"), "1");
    ASSERT_EQ(output.shader_info.alias.at("strength"), "g_Strength");
    ASSERT_EQ(output.shader_info.svs.at("g_Strength").size(), 1u);
    ASSERT_EQ(output.shader_info.defTexs.at(0).second, "materials/default.png");
    ASSERT_TRUE(output.fragment_preprocessor_info.active_tex_slots.contains(2));

    ASSERT_TRUE(output.fragment_preprocessor_info.active_tex_slots.contains(0));
}

TEST(RustShaderBridge, AnalysesATinyProgramWithoutGeneratingCode)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::shader::RustShaderOutput output;

    ASSERT_TRUE(wallpaper::shader::CompileRustShaderProgram(TinyRequest(), output));
    ASSERT_TRUE(output.metal_stages.empty());
    ASSERT_FALSE(output.metadata_json.empty());
    ASSERT_FALSE(output.reflection_json.empty());
#endif
}

TEST(RustShaderBridge, CompilesWithRegisteredLegalizerPolicies)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::shader::RustShaderOutput output;

    ASSERT_TRUE(wallpaper::shader::CompileRustShaderProgram(TinyRequest(), output))
        << wallpaper::shader::LastRustShaderError();

    ASSERT_FALSE(output.reflection_json.empty());
    const auto reflection = nlohmann::json::parse(output.reflection_json);
    const auto inputs     = reflection.value("vertex_inputs", nlohmann::json::array());
    ASSERT_TRUE(std::any_of(inputs.begin(), inputs.end(), [](const nlohmann::json& input) {
        return input.value("name", std::string {}) == "a_Position";
    }));
#endif
}

TEST(RustShaderBridge, RuntimeReflectionOmitsInactiveTextureDescriptors)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    auto request = TinyRequest();
    request.shader_name = "bridge/inactive-texture-descriptor";
    request.cache_enabled = false;
    request.stages.at(1).source =
        "varying vec2 v_Uv;\n"
        "uniform sampler2D g_Texture0;\n"
        "uniform sampler2D g_Texture1;\n"
        "void main() { gl_FragColor = texture2D(g_Texture0, v_Uv); }\n";
    request.textures.push_back(RustShaderTextureInfo {
        .slot       = 1,
        .present    = true,
        .enabled    = true,
        .format     = "rgba8",
        .components = { false, false, false },
    });

    wallpaper::shader::RustShaderOutput output;
    ASSERT_TRUE(wallpaper::shader::CompileRustShaderProgram(request, output))
        << wallpaper::shader::LastRustShaderError();

    const auto names = DescriptorNames(output);
    ASSERT_TRUE(names.contains("g_Texture0"));
    ASSERT_TRUE(names.contains("_we_Sampler_g_Texture0"));
    ASSERT_FALSE(names.contains("g_Texture1"));
    ASSERT_FALSE(names.contains("_we_Sampler_g_Texture1"));
#endif
}

TEST(RustShaderBridge, AbsentTextureSlotDoesNotEnableAnnotationCombo)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    auto request          = TinyRequest();
    request.shader_name   = "bridge/absent-texture-combo";
    request.cache_enabled = false;
    request.stages.at(1).source =
        "// [COMBO] {\"combo\":\"LIGHTING\",\"default\":1}\n"
        "varying vec2 v_Uv;\n"
        "uniform sampler2D g_Texture0;\n"
        "#if LIGHTING\n"
        "uniform sampler2D g_Texture1; // {\"combo\":\"NORMALMAP\"}\n"
        "#endif\n"
        "void main() {\n"
        "  vec4 color = texture2D(g_Texture0, v_Uv);\n"
        "#if LIGHTING && NORMALMAP\n"
        "  color += texture2D(g_Texture1, v_Uv);\n"
        "#endif\n"
        "  gl_FragColor = color;\n"
        "}\n";
    request.textures.push_back(RustShaderTextureInfo {
        .slot       = 1,
        .present    = false,
        .enabled    = false,
        .format     = "rgba8",
        .components = { false, false, false },
    });

    const auto request_json = wallpaper::shader::BuildRustShaderRequestJson(request);
    ASSERT_FALSE(request_json.at("textures").at(1).at("present").get<bool>());

    wallpaper::shader::RustShaderOutput output;
    ASSERT_TRUE(wallpaper::shader::CompileRustShaderProgram(request, output))
        << wallpaper::shader::LastRustShaderError();

    ASSERT_EQ(output.shader_info.combos.at("NORMALMAP"), "0")
        << "request: " << request_json.dump()
        << "\nmetadata: " << output.metadata_json;
    const auto names = DescriptorNames(output);
    ASSERT_TRUE(names.contains("g_Texture0"));
    ASSERT_FALSE(names.contains("g_Texture1"));
    ASSERT_FALSE(names.contains("_we_Sampler_g_Texture1"));
#endif
}

TEST(RustShaderBridge, CompilesWithEmptyIncludeCallbackPayload)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::shader::RustShaderOutput output;
    bool                               include_requested = false;

    ASSERT_TRUE(wallpaper::shader::CompileRustShaderProgramWithBridgeJson(
        RequestJsonWithInclude("empty.glsl"),
        output,
        [&include_requested](std::string_view path) -> std::optional<std::string> {
            include_requested = path == "empty.glsl";
            return std::string {};
        }));

    ASSERT_TRUE(include_requested);
    ASSERT_FALSE(output.metadata_json.empty());
#endif
}

TEST(RustShaderBridge, FailedCompileClearsPreviousOutput)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::shader::RustShaderOutput output;
    ASSERT_TRUE(wallpaper::shader::CompileRustShaderProgram(TinyRequest(), output));
    ASSERT_FALSE(output.metadata_json.empty());

    auto invalid = wallpaper::shader::BuildRustShaderRequestJson(TinyRequest());
    invalid["stages"] = nlohmann::json::array();

    ASSERT_FALSE(wallpaper::shader::CompileRustShaderProgramWithBridgeJson(invalid, output));
    ASSERT_TRUE(output.metadata_json.empty());
    ASSERT_TRUE(output.reflection_json.empty());
#endif
}

TEST(RustShaderBridge, WPShaderParserAnalyzeRustPopulatesMetadataReflectionAndPreprocessInfo)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::fs::VFS                 vfs;
    wallpaper::WPShaderInfo            shader_info;
    std::string                        reflection_json;
    std::vector<wallpaper::WPShaderTexInfo> textures {
        wallpaper::WPShaderTexInfo {
            .present       = true,
            .enabled       = true,
            .composEnabled = { false, false, false },
        },
    };
    auto units = ParserBridgeUnits();

    ASSERT_TRUE(wallpaper::WPShaderParser::AnalyzeRust(
        "parser-bridge-scene",
        "tests/parser-bridge",
        units,
        vfs,
        &shader_info,
        textures,
        &reflection_json))
        << wallpaper::shader::LastRustShaderError();

    ASSERT_FALSE(reflection_json.empty());
    const auto reflection = nlohmann::json::parse(reflection_json);
    const auto descriptors = reflection.value("descriptor_bindings", nlohmann::json::array());
    EXPECT_FALSE(descriptors.empty());
    const auto texture_descriptor = std::find_if(
        descriptors.begin(), descriptors.end(), [](const nlohmann::json& descriptor) {
            return descriptor.value("name", "") == "g_Texture0";
        });
    ASSERT_NE(texture_descriptor, descriptors.end());
    EXPECT_EQ(texture_descriptor->value("descriptor", ""), "sampled_image");
    const auto sampler_descriptor = std::find_if(
        descriptors.begin(), descriptors.end(), [](const nlohmann::json& descriptor) {
            return descriptor.value("name", "") == "_we_Sampler_g_Texture0";
        });
    ASSERT_NE(sampler_descriptor, descriptors.end());
    EXPECT_EQ(sampler_descriptor->value("descriptor", ""), "sampler");
    EXPECT_FALSE(reflection.value("vertex_inputs", nlohmann::json::array()).empty());

    ASSERT_EQ(shader_info.defTexs.size(), 1u);
    EXPECT_EQ(shader_info.defTexs.at(0).first, 0);
    EXPECT_EQ(shader_info.defTexs.at(0).second, "materials/default.png");
    EXPECT_EQ(shader_info.combos.at("HAS_TEXTURE"), "1");
    EXPECT_EQ(shader_info.alias.at("albedo"), "g_Texture0");
    EXPECT_EQ(shader_info.alias.at("brightness"), "g_Brightness");
    ASSERT_EQ(shader_info.svs.at("g_Brightness").size(), 1u);
    EXPECT_FLOAT_EQ(shader_info.svs.at("g_Brightness")[0], 1.25f);

    EXPECT_TRUE(units.at(1).preprocess_info.active_tex_slots.contains(0));
#endif
}

TEST(RustShaderBridge, WPShaderParserAnalyzeRustReportsGeneratedFragmentPath)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::fs::VFS                 vfs;
    wallpaper::WPShaderInfo            shader_info;
    std::string                        reflection_json;
    std::vector<wallpaper::WPShaderTexInfo> textures {
        wallpaper::WPShaderTexInfo {
            .enabled       = true,
            .composEnabled = { false, false, false },
        },
    };
    auto units = ParserBridgeUnits();
    units.at(1).src =
        "varying vec2 v_Uv;\n"
        "void main() {\n"
        "  gl_FragColor = missing_value;\n"
        "}\n";

    ASSERT_FALSE(wallpaper::WPShaderParser::AnalyzeRust(
        "parser-bridge-scene",
        "tests/parser-bridge-invalid",
        units,
        vfs,
        &shader_info,
        textures,
        &reflection_json));

    const auto error = wallpaper::shader::LastRustShaderError();
    EXPECT_NE(error.find("generated/fragment.glsl"), std::string::npos) << error;
#endif
}

TEST(RustShaderBridge, BuildsMetalTargetRequestJson)
{
    auto request   = TinyRequest();
    request.target = wallpaper::shader::RustShaderTarget::MetalMsl;

    const auto json = wallpaper::shader::BuildRustShaderRequestJson(request);

    ASSERT_EQ(json.at("target"), "metal_msl");
    ASSERT_EQ(json.at("stages").at(0).at("kind"), "vertex");
}

TEST(RustShaderBridge, WPShaderParserCompileToMslRustReturnsSourceBindingsAndReflection)
{
#ifndef WESCENE_HAS_RUST_SHADER_FFI
    GTEST_SKIP() << "Rust shader staticlib was not linked";
#else
    wallpaper::fs::VFS                      vfs;
    wallpaper::WPShaderInfo                 shader_info;
    std::string                             reflection_json;
    std::vector<wallpaper::WPShaderTexInfo> textures {
        wallpaper::WPShaderTexInfo {
            .present       = true,
            .enabled       = true,
            .composEnabled = { false, false, false },
        },
    };
    auto                                                     units = ParserBridgeUnits();
    std::vector<wallpaper::shader::RustShaderMetalStage> stages;

    ASSERT_TRUE(wallpaper::WPShaderParser::CompileToMslRust("parser-bridge-scene",
                                                            "tests/parser-bridge-metal",
                                                            units,
                                                            stages,
                                                            vfs,
                                                            &shader_info,
                                                            textures,
                                                            &reflection_json))
        << wallpaper::shader::LastRustShaderError();

    ASSERT_EQ(stages.size(), 2u);
    EXPECT_EQ(stages.at(0).kind, ShaderType::VERTEX);
    EXPECT_EQ(stages.at(1).kind, ShaderType::FRAGMENT);
    EXPECT_EQ(stages.at(0).language_version, "2.0");

    for (const auto& stage : stages) {
        EXPECT_NE(stage.source.find("#include <metal_stdlib>"), std::string::npos);
        // Naga renames entry points; callers must use the reported name.
        ASSERT_FALSE(stage.entry_point.empty());
        EXPECT_NE(stage.entry_point, "main");
        EXPECT_NE(stage.source.find(stage.entry_point + "("), std::string::npos);
        EXPECT_FALSE(stage.conventions.clip_space_y_flipped);
        EXPECT_FALSE(stage.conventions.clip_space_depth_remapped);
        EXPECT_FALSE(stage.conventions.texture_origin_flipped);
    }

    const auto& fragment_bindings = stages.at(1).bindings;
    const auto  texture_binding =
        std::find_if(fragment_bindings.begin(),
                     fragment_bindings.end(),
                     [](const wallpaper::shader::RustShaderMetalBinding& binding) {
                         return binding.name == "g_Texture0";
                     });
    ASSERT_NE(texture_binding, fragment_bindings.end());
    EXPECT_EQ(texture_binding->set, 0u);
    EXPECT_EQ(texture_binding->slot_kind, wallpaper::shader::RustShaderMetalSlotKind::Texture);
    // The mapping the Metal backend reproduces: metal slot == GLSL binding.
    EXPECT_EQ(texture_binding->slot, texture_binding->binding);

    const auto sampler_binding =
        std::find_if(fragment_bindings.begin(),
                     fragment_bindings.end(),
                     [](const wallpaper::shader::RustShaderMetalBinding& binding) {
                         return binding.name == "_we_Sampler_g_Texture0";
                     });
    ASSERT_NE(sampler_binding, fragment_bindings.end());
    EXPECT_EQ(sampler_binding->slot_kind, wallpaper::shader::RustShaderMetalSlotKind::Sampler);
    EXPECT_EQ(sampler_binding->slot, sampler_binding->binding);
    EXPECT_NE(texture_binding->binding, sampler_binding->binding);

    // The Metal target must return the reflection payload; the Metal backend reads uniform layout and texture slot
    // names from it.
    ASSERT_FALSE(reflection_json.empty());
    const auto reflection  = nlohmann::json::parse(reflection_json);
    const auto descriptors = reflection.value("descriptor_bindings", nlohmann::json::array());
    EXPECT_FALSE(descriptors.empty());
    EXPECT_FALSE(reflection.value("vertex_inputs", nlohmann::json::array()).empty());
    EXPECT_EQ(shader_info.alias.at("albedo"), "g_Texture0");
    EXPECT_TRUE(units.at(1).preprocess_info.active_tex_slots.contains(0));
#endif
}

TEST(RustShaderBridge, MetalAndAnalysisTargetsUseDifferentProgramCacheKeys)
{
    auto analysis_request = TinyRequest();
    auto metal_request    = TinyRequest();
    metal_request.target  = wallpaper::shader::RustShaderTarget::MetalMsl;

    EXPECT_NE(wallpaper::shader::BuildRustShaderRequestJson(analysis_request).dump(),
              wallpaper::shader::BuildRustShaderRequestJson(metal_request).dump());
}

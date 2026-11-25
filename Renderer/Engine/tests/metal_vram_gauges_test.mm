// Atomic VRAM and EDR gauges on MetalRender:
// - Updated on graph compile, target resize, and graph release with zero per-frame work.
// - Match RenderTargetBytesForTests / GeometryBufferBytesForTests.
// - Stay completely unchanged across steady-state draws.
// - Populate RendererCounters slots even while per-frame event counting is off.

#include <gtest/gtest.h>

#include "Core/RendererCounters.hpp"
#include "MetalRender/MetalRender.hpp"
#include "Scene/Scene.h"
#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace
{
using namespace we_test;

constexpr uint32_t kWidth  = 512;
constexpr uint32_t kHeight = 288;

void MakeSimpleScene(ScenePackage& package)
{
    Image image { kWidth, kHeight, std::vector<uint8_t>(kWidth * kHeight * 4, 200) };
    TexOptions opts;
    opts.point_sampling = false;
    const std::string texture = package.AddTexture("solid", image, opts);
    ImageLayer layer;
    layer.model  = package.AddImageModel("solid", texture);
    layer.origin = { kWidth / 2.0f, kHeight / 2.0f, 0.0f };
    layer.size   = { static_cast<float>(kWidth), static_cast<float>(kHeight) };
    SceneGeneral general;
    general.canvas_width  = static_cast<int>(kWidth);
    general.canvas_height = static_cast<int>(kHeight);
    package.SetProject();
    package.SetScene(SceneJson(general, { ImageLayerJson(layer) }));
}
} // namespace

TEST(MetalVramGauges, TrackCompileResizeAndStayStableAcrossDraws)
{
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    MakeSimpleScene(package);

    GpuSceneOptions options;
    options.width              = kWidth;
    options.height             = kHeight;
    options.render_scale       = 1.0;
    options.scene_optimization = false;

    GpuScene scene(package, options);
    ASSERT_TRUE(scene.ok()) << scene.error();

    auto& render = scene.renderer();
    const uint64_t compiled_targets  = render.RenderTargetBytes();
    const uint64_t compiled_geometry = render.GeometryBufferBytes();
    EXPECT_GT(compiled_targets, 0u);
    EXPECT_GT(compiled_geometry, 0u);
    EXPECT_EQ(compiled_targets, render.RenderTargetBytesForTests());
    EXPECT_EQ(compiled_geometry, render.GeometryBufferBytesForTests());
    EXPECT_FALSE(render.SurfaceEDRActive());

    // Gauges publish immediately to attached RendererCounters even with event counting off.
    wallpaper::RendererCounters counters;
    ASSERT_FALSE(wallpaper::RendererCounters::Enabled());
    render.SetCounters(&counters);
    EXPECT_EQ(counters.Get(OWE_RC_RENDER_TARGET_BYTES), compiled_targets);
    EXPECT_EQ(counters.Get(OWE_RC_GEOMETRY_BUFFER_BYTES), compiled_geometry);
    EXPECT_EQ(counters.Get(OWE_RC_EDR_ACTIVE), 0u);

    // Steady-state draws leave both atomic gauges and counter slots completely unchanged.
    ASSERT_TRUE(scene.Step(5));
    EXPECT_EQ(render.RenderTargetBytes(), compiled_targets);
    EXPECT_EQ(render.GeometryBufferBytes(), compiled_geometry);
    EXPECT_EQ(counters.Get(OWE_RC_RENDER_TARGET_BYTES), compiled_targets);
    EXPECT_EQ(counters.Get(OWE_RC_GEOMETRY_BUFFER_BYTES), compiled_geometry);

    // Resizing targets to half render scale drops render-target VRAM while keeping geometry intact.
    scene.scene().render_scale = 0.5;
    ASSERT_TRUE(render.ResizeRenderTargets(scene.scene()));
    const uint64_t half_targets = render.RenderTargetBytes();
    EXPECT_GT(half_targets, 0u);
    EXPECT_LT(half_targets, compiled_targets);
    EXPECT_EQ(half_targets, render.RenderTargetBytesForTests());
    EXPECT_EQ(render.GeometryBufferBytes(), compiled_geometry);
    EXPECT_EQ(counters.Get(OWE_RC_RENDER_TARGET_BYTES), half_targets);
    EXPECT_EQ(counters.Get(OWE_RC_GEOMETRY_BUFFER_BYTES), compiled_geometry);

    // Further draws at half scale leave the resized gauges stable.
    ASSERT_TRUE(scene.Step(3));
    EXPECT_EQ(render.RenderTargetBytes(), half_targets);
    EXPECT_EQ(render.GeometryBufferBytes(), compiled_geometry);

    // Resizing back to native restores the original render-target byte count.
    scene.scene().render_scale = 1.0;
    ASSERT_TRUE(render.ResizeRenderTargets(scene.scene()));
    EXPECT_EQ(render.RenderTargetBytes(), compiled_targets);
    EXPECT_EQ(counters.Get(OWE_RC_RENDER_TARGET_BYTES), compiled_targets);

    // Resetting event counters clears event slots while preserving always-live gauges.
    wallpaper::RendererCounters::SetEnabled(true);
    counters.Add(OWE_RC_DRAWS_EXECUTED, 7);
    counters.SetGauge(OWE_RC_EDR_ACTIVE, 1u);
    wallpaper::RendererCounters::SetEnabled(false);
    EXPECT_EQ(counters.Get(OWE_RC_DRAWS_EXECUTED), 7u);
    counters.Reset();
    EXPECT_EQ(counters.Get(OWE_RC_DRAWS_EXECUTED), 0u);
    EXPECT_EQ(counters.Get(OWE_RC_RENDER_TARGET_BYTES), compiled_targets);
    EXPECT_EQ(counters.Get(OWE_RC_GEOMETRY_BUFFER_BYTES), compiled_geometry);
    EXPECT_EQ(counters.Get(OWE_RC_EDR_ACTIVE), 1u);
    counters.SetGauge(OWE_RC_EDR_ACTIVE, 0u);

    // Releasing the graph zeros both gauges and the counter slots.
    ASSERT_TRUE(render.clearLastRenderGraph());
    EXPECT_EQ(render.RenderTargetBytes(), 0u);
    EXPECT_EQ(render.GeometryBufferBytes(), 0u);
    EXPECT_EQ(counters.Get(OWE_RC_RENDER_TARGET_BYTES), 0u);
    EXPECT_EQ(counters.Get(OWE_RC_GEOMETRY_BUFFER_BYTES), 0u);

    render.SetCounters(nullptr);
}

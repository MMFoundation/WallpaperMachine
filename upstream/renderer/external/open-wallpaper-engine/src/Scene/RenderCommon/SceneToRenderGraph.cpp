#include "RenderCommon/SceneToRenderGraph.hpp"

#include "RenderCommon/ScenePass.hpp"
#include "RenderGraph/RenderGraph.hpp"

std::unique_ptr<wallpaper::rg::RenderGraph> wallpaper::sceneToRenderGraph(Scene&) {
    // CLEANROOM RG21
    return std::make_unique<rg::RenderGraph>();
}

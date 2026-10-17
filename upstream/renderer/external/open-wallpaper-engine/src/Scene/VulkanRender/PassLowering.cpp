#include "PassLowering.hpp"

#include "CopyPass.hpp"
#include "CustomShaderPass.hpp"
#include "PrePass.hpp"
#include "RenderCommon/ScenePass.hpp"
#include "Vulkan/SampleCount.hpp"

namespace wallpaper::vulkan
{

std::unique_ptr<VulkanPass> LowerGraphPass(const rg::Pass& step)
{
    if (const auto* clear = dynamic_cast<const rg::ClearPass*>(&step)) {
        PrePass::Desc desc;
        desc.result      = clear->desc().result;
        desc.transparent = clear->desc().transparent;
        return std::make_unique<PrePass>(desc);
    }
    if (const auto* copy = dynamic_cast<const rg::CopyPass*>(&step)) {
        CopyPass::Desc desc;
        desc.src = copy->desc().src;
        desc.dst = copy->desc().dst;
        return std::make_unique<CopyPass>(desc);
    }
    if (const auto* draw = dynamic_cast<const rg::DrawPass*>(&step)) {
        CustomShaderPass::Desc desc { draw->desc() };
        desc.sample_count = SampleCountFromValue(draw->desc().samples);
        return std::make_unique<CustomShaderPass>(desc);
    }
    return nullptr;
}

} // namespace wallpaper::vulkan

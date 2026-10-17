#pragma once

#include "VulkanPass.hpp"

#include <memory>

namespace wallpaper
{
namespace rg
{
class Pass;
}

namespace vulkan
{

/// Turns one step of the render graph, which `sceneToRenderGraph` describes in
/// backend-neutral terms (`rg::ClearPass`, `rg::CopyPass`, `rg::DrawPass`), into
/// the executable pass this backend records. The pass starts from a copy of the
/// step's description with nothing prepared; the step itself is not changed, so
/// compiling the same graph again lowers it again.
///
/// Null for a step that is none of those three.
[[nodiscard]] std::unique_ptr<VulkanPass> LowerGraphPass(const rg::Pass& step);

} // namespace vulkan
} // namespace wallpaper

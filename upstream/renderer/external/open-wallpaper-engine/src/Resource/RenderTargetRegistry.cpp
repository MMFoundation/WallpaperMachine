#include "Resource/RenderTargetRegistry.hpp"

namespace wallpaper
{

RenderTargetRegistry::RenderTargetRegistry(
    std::unordered_map<std::string, SceneRenderTarget>& targets,
    std::unordered_map<std::string, std::string>& aliases)
    : m_targets(&targets),
      m_aliases(&aliases)
{
}

RenderTargetRegistry::RenderTargetRegistry(
    const std::unordered_map<std::string, SceneRenderTarget>& targets,
    const std::unordered_map<std::string, std::string>& aliases)
    : m_owned_targets(targets),
      m_owned_aliases(aliases)
{
}

void RenderTargetRegistry::installBuiltIns(int, int)
{
    // CLEANROOM U38: implement from specs/engine/e7-small-units.md
}

void RenderTargetRegistry::insert(std::string, SceneRenderTarget)
{
    // CLEANROOM U39: implement from specs/engine/e7-small-units.md
}

void RenderTargetRegistry::alias(std::string, std::string)
{
    // CLEANROOM U40: implement from specs/engine/e7-small-units.md
}

bool RenderTargetRegistry::contains(std::string_view) const
{
    // CLEANROOM U41: implement from specs/engine/e7-small-units.md
    return false;
}

std::string RenderTargetRegistry::resolve(std::string_view) const
{
    // CLEANROOM U42: implement from specs/engine/e7-small-units.md
    return {};
}

const SceneRenderTarget* RenderTargetRegistry::lookup(std::string_view) const
{
    // CLEANROOM U43: implement from specs/engine/e7-small-units.md
    return nullptr;
}

} // namespace wallpaper

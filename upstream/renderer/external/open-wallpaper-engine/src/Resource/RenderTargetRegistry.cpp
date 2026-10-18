// This project's own code, written from the clean-room specification
// (specs/engine/e7-small-units.md).
#include "Resource/RenderTargetRegistry.hpp"

#include <algorithm>

#include "SpecTexs.hpp"

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

// Adds the targets every scene has: the scene colour buffer, the mip-mapped copy
// bound to it, the quarter and eighth size scratch targets, `_rt_Bloom`, and the
// shadow atlas with the alias light cookies are looked up by. Sizes follow the
// given colour-buffer size, at least one pixel on each side.
void RenderTargetRegistry::installBuiltIns(int width, int height)
{
    const int w = std::max(1, width);
    const int h = std::max(1, height);

    SceneRenderTarget frame {};
    frame.width           = w;
    frame.height          = h;
    frame.authored_width  = w;
    frame.authored_height = h;
    frame.bind            = { .enable = true, .screen = true };
    insert(std::string(SpecTex_Default), frame);

    SceneRenderTarget mip {};
    mip.width      = w;
    mip.height     = h;
    mip.has_mipmap = true;
    mip.bind       = { .enable = true, .name = std::string(SpecTex_Default) };
    insert(std::string(WE_MIP_MAPPED_FRAME_BUFFER), mip);

    const auto scratch = [&](std::string name, int divisor) {
        SceneRenderTarget target {};
        target.width      = std::max(1, w / divisor);
        target.height     = std::max(1, h / divisor);
        target.allowReuse = true;
        insert(std::move(name), target);
    };
    scratch("_rt_4FrameBuffer", 4);
    scratch("_rt_8FrameBuffer", 8);
    scratch("_rt_Bloom", 8);

    SceneRenderTarget atlas {};
    atlas.width      = w;
    atlas.height     = h;
    atlas.allowReuse = true;
    insert("_rt_shadowAtlas", atlas);
    alias("_alias_lightCookie", "_rt_shadowAtlas");
}

void RenderTargetRegistry::insert(std::string name, SceneRenderTarget target)
{
    (*m_targets)[std::move(name)] = std::move(target);
}

void RenderTargetRegistry::alias(std::string alias_name, std::string target_name)
{
    (*m_aliases)[std::move(alias_name)] = std::move(target_name);
}

bool RenderTargetRegistry::contains(std::string_view name) const
{
    return m_targets->find(resolve(name)) != m_targets->end();
}

// An alias name gives the name it stands for (following aliases of aliases, and
// stopping if they loop); any other name gives itself.
std::string RenderTargetRegistry::resolve(std::string_view name) const
{
    std::string current(name);
    for (std::size_t hops = 0; hops <= m_aliases->size(); ++hops) {
        const auto it = m_aliases->find(current);
        if (it == m_aliases->end()) break;
        current = it->second;
    }
    return current;
}

const SceneRenderTarget* RenderTargetRegistry::lookup(std::string_view name) const
{
    const auto it = m_targets->find(resolve(name));
    return it == m_targets->end() ? nullptr : &it->second;
}

} // namespace wallpaper

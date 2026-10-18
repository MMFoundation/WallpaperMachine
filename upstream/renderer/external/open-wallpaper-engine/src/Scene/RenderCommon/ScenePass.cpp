#include "RenderCommon/ScenePass.hpp"

#include <cassert>

namespace wallpaper::rg
{

ClearPass::ClearPass(const Desc& desc): m_desc(desc) {}
ClearPass::~ClearPass() = default;

CopyPass::CopyPass(const Desc& desc): m_desc(desc) {}
CopyPass::~CopyPass() = default;

DrawPass::DrawPass(const Desc& desc): m_desc(desc) {}
DrawPass::~DrawPass() = default;

void DrawPass::setDescTex(uint32_t, std::string_view)
{
    // CLEANROOM RG13
}

uint32_t NormalizeSampleCount(uint32_t requested)
{
    switch (requested) {
    case 64:
    case 32:
    case 16:
    case 8:
    case 4:
    case 2: return requested;
    case 1:
    default: return 1;
    }
}

} // namespace wallpaper::rg

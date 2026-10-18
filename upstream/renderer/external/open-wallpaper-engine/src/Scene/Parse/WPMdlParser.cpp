#include "WPMdlParser.hpp"

using namespace wallpaper;

// The clean-room rewrite is specified in .plans/own-code/specs/parse/p5-models-puppets.md
// (stub ledger, section 12). Each marker below stands for one body to implement.

bool WPMdlParser::Parse(std::string_view, fs::VFS&, WPMdl&) {
    // CLEANROOM LM1
    return false;
}

void WPMdlParser::GenMeshFromMdl(SceneMesh::Submesh&, const WPMdl::Mesh&) {
    // CLEANROOM LM2
}

void WPMdlParser::GenMaskSubmeshFromMdl(SceneMesh::Submesh&, const WPMdl::Mesh&,
                                        std::span<const uint32_t>) {
    // CLEANROOM LM3
}

void WPMdlParser::GenPuppetMesh(SceneMesh&, const WPMdl&, const bool) {
    // CLEANROOM LM4
}

void WPMdlParser::AddPuppetShaderInfo(WPShaderInfo&, const WPMdl&) {
    // CLEANROOM LM5
}

void WPMdlParser::AddPuppetMatInfo(wpscene::WPMaterial&, const WPMdl&) {
    // CLEANROOM LM6
}

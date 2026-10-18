#include "RenderGraph.hpp"

namespace wallpaper::rg
{

RenderGraph::RenderGraph() {
    // CLEANROOM RG6
}

PassNode* RenderGraph::getPassNode(NodeID) const {
    // CLEANROOM RG6
    return nullptr;
}

TexNode* RenderGraph::getTexNode(NodeID) const {
    // CLEANROOM RG6
    return nullptr;
}

Pass* RenderGraph::getPass(NodeID) const {
    // CLEANROOM RG6
    return nullptr;
}

std::vector<NodeID> RenderGraph::topologicalOrder() const {
    // CLEANROOM RG7
    return {};
}

RenderGraphBuilder::RenderGraphBuilder(RenderGraph&) {
    // CLEANROOM RG8
}

TexNode* RenderGraphBuilder::createTexNode(const TexNode::Desc&, bool) {
    // CLEANROOM RG8
    return nullptr;
}

void RenderGraphBuilder::setWorkPassNode(PassNode*) {
    // CLEANROOM RG9
}

void RenderGraphBuilder::markSelfWrite(TexNode*) {
    // CLEANROOM RG9
}

void RenderGraphBuilder::markVirtualWrite(TexNode*) {
    // CLEANROOM RG9
}

void RenderGraphBuilder::read(TexNode*) {
    // CLEANROOM RG9
}

void RenderGraphBuilder::write(TexNode*) {
    // CLEANROOM RG9
}

const PassNode& RenderGraphBuilder::workPassNode() const {
    // CLEANROOM RG9
    static const PassNode placeholder {};
    return placeholder;
}

std::vector<std::vector<TexNode*>> RenderGraph::getLastReadTexs(std::span<const NodeID> nodes) const {
    // CLEANROOM RG11
    return std::vector<std::vector<TexNode*>>(nodes.size());
}

std::vector<std::string> RenderGraph::getCarriedOverKeys(std::span<const NodeID>) const {
    // CLEANROOM RG12
    return {};
}

} // namespace wallpaper::rg

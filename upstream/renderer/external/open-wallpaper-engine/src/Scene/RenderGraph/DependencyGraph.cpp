#include "DependencyGraph.hpp"

namespace wallpaper::rg
{

std::vector<NodeID> DependencyGraph::GetNodeOut(NodeID) const {
    // CLEANROOM RG1
    return {};
}

std::vector<NodeID> DependencyGraph::GetNodeIn(NodeID) const {
    // CLEANROOM RG1
    return {};
}

NodeID DependencyGraph::AddNode(std::unique_ptr<Node>&&) {
    // CLEANROOM RG1
    return 0;
}

void DependencyGraph::Connect(NodeID, NodeID) {
    // CLEANROOM RG1
}

std::vector<NodeID> DependencyGraph::TopologicalOrder() const {
    // CLEANROOM RG2
    return {};
}

void DependencyGraph::ToGraphviz(std::string_view) const {
    // CLEANROOM RG3
}

} // namespace wallpaper::rg

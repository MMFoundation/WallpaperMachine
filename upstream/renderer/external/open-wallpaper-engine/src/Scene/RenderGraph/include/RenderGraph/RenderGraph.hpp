#pragma once

#include "PassNode.hpp"

#include "TexNode.hpp"
#include "Core/MapSet.hpp"
#include <span>

namespace wallpaper
{
namespace rg
{

class Pass;
class RenderGraph;
class RenderGraphBuilder {
public:
    RenderGraphBuilder(RenderGraph&);

    TexNode*        createTexNode(const TexNode::Desc&, bool write = false);
    void            read(TexNode*);
    void            write(TexNode*);
    const PassNode& workPassNode() const;
    void            setWorkPassNode(PassNode*);
    void            markSelfWrite(TexNode*);
    void            markVirtualWrite(TexNode*);
};

class RenderGraph {
public:
    RenderGraph();

    PassNode* getPassNode(NodeID) const;
    TexNode*  getTexNode(NodeID) const;
    Pass*     getPass(NodeID) const;

    std::vector<NodeID>                topologicalOrder() const;
    std::vector<std::vector<TexNode*>> getLastReadTexs(std::span<const NodeID>) const;
    std::vector<std::string>           getCarriedOverKeys(std::span<const NodeID>) const;

    void ToGraphviz(std::string_view) const {
        // CLEANROOM RG6
    }

    template<typename CB>
    bool afterBuild(NodeID, CB&&) {
        // CLEANROOM RG10
        return false;
    }

    template<typename TPass, typename CB>
    PassNode* addPass(std::string_view, PassNode::Type, CB&&) {
        // CLEANROOM RG10
        return nullptr;
    }
};

} // namespace rg
} // namespace wallpaper

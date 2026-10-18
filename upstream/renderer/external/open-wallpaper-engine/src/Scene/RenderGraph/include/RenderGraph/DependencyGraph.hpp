#pragma once
#include <cstdint>
#include <vector>
#include <numeric>
#include <memory>
#include <unordered_set>
#include <string>
#include <string_view>

#include "Core/Literals.hpp"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{
namespace rg
{

typedef size_t NodeID;

class DependencyGraph : NoCopy {
public:
    class Node : NoCopy {
    public:
        Node()          = default;
        virtual ~Node() = default;

        NodeID ID() const {
            // CLEANROOM RG1
            return 0;
        }
        std::string GraphID() const {
            // CLEANROOM RG1
            return {};
        }
        virtual std::string ToGraphviz() const {
            // CLEANROOM RG3
            return {};
        }
    };

    DependencyGraph()  = default;
    ~DependencyGraph() = default;

    DependencyGraph(DependencyGraph&&) {
        // CLEANROOM RG1
    }
    DependencyGraph& operator=(DependencyGraph&&) {
        // CLEANROOM RG1
        return *this;
    }

    size_t NodeNum() const {
        // CLEANROOM RG1
        return 0;
    }
    size_t EdgeNum() const {
        // CLEANROOM RG1
        return 0;
    }
    Node* GetNode(NodeID) const {
        // CLEANROOM RG1
        return nullptr;
    }

    std::vector<NodeID> GetNodeOut(NodeID) const;
    std::vector<NodeID> GetNodeIn(NodeID) const;

    NodeID AddNode(std::unique_ptr<Node>&&);
    void   Connect(NodeID, NodeID);

    bool                HasCycle() const;
    std::vector<NodeID> TopologicalOrder() const;

    void ToGraphviz(std::string_view) const;
};
} // namespace rg
} // namespace wallpaper

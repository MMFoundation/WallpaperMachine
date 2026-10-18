#include "PassNode.hpp"

namespace wallpaper::rg
{

PassNode* PassNode::addPassNode(DependencyGraph&, PassNode::Type) {
    // CLEANROOM RG5
    return nullptr;
}

PassNode::Type PassNode::type() const {
    // CLEANROOM RG5
    return Type::Virtual;
}

std::string_view PassNode::name() const {
    // CLEANROOM RG5
    return {};
}

void PassNode::setName(std::string_view) {
    // CLEANROOM RG5
}

std::string PassNode::ToGraphviz() const {
    // CLEANROOM RG3
    return {};
}

} // namespace wallpaper::rg

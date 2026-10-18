#include "TexNode.hpp"
#include "PassNode.hpp"

namespace wallpaper::rg
{

TexNode* TexNode::addTexNode(DependencyGraph&, const Desc&) {
    // CLEANROOM RG4
    return nullptr;
}

TexNode* TexNode::addNewVersion(DependencyGraph&, TexNode*) {
    // CLEANROOM RG4
    return nullptr;
}

TexNode::Desc TexNode::genDesc() const {
    // CLEANROOM RG4
    return Desc { .name = {}, .key = {}, .type = TexType::Temp };
}

TexNode::TexType TexNode::type() const {
    // CLEANROOM RG4
    return TexType::Temp;
}

std::string_view TexNode::name() const {
    // CLEANROOM RG4
    return {};
}

std::string_view TexNode::key() const {
    // CLEANROOM RG4
    return {};
}

size_t TexNode::version() const {
    // CLEANROOM RG4
    return 0;
}

PassNode* TexNode::writer() const {
    // CLEANROOM RG4
    return nullptr;
}

TexNode* TexNode::preVer() const {
    // CLEANROOM RG4
    return nullptr;
}

TexNode* TexNode::nextVer() const {
    // CLEANROOM RG4
    return nullptr;
}

void TexNode::setName(std::string_view) {
    // CLEANROOM RG4
}

void TexNode::setKey(std::string_view) {
    // CLEANROOM RG4
}

void TexNode::setWriter(PassNode*) {
    // CLEANROOM RG4
}

std::string TexNode::ToGraphviz() const {
    // CLEANROOM RG3
    return {};
}

} // namespace wallpaper::rg

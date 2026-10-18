#include "SceneVertexArray.h"

using namespace wallpaper;

uint8_t SceneVertexArray::TypeCount(VertexType t) {
    // CLEANROOM SM17
    (void)t;
    return 0;
}

uint8_t SceneVertexArray::RealAttributeSize(const SceneVertexArray::SceneVertexAttribute& attr) {
    // CLEANROOM SM17
    (void)attr;
    return 0;
}

SceneVertexArray::SceneVertexArray(const std::vector<SceneVertexAttribute>& attrs,
                                   const usize                              count) {
    // CLEANROOM SM16
    (void)attrs;
    (void)count;
}

SceneVertexArray::~SceneVertexArray() {
    // CLEANROOM SM16
}

SceneVertexArray::SceneVertexArray(SceneVertexArray&& o) noexcept {
    // CLEANROOM SM16
    (void)o;
}

SceneVertexArray& SceneVertexArray::operator=(SceneVertexArray&& o) noexcept {
    // CLEANROOM SM16
    (void)o;
    return *this;
}

bool SceneVertexArray::AddVertex(const float* data) {
    // CLEANROOM SM16
    (void)data;
    return false;
}

bool SceneVertexArray::SetVertex(std::string_view name, std::span<const float> data) noexcept {
    // CLEANROOM SM16
    (void)name;
    (void)data;
    return false;
}

bool SceneVertexArray::SetVertexs(usize index, std::span<const float> data) noexcept {
    // CLEANROOM SM16
    (void)index;
    (void)data;
    return false;
}

Map<std::string, SceneVertexArray::SceneVertexAttributeOffset>
SceneVertexArray::GetAttrOffsetMap() const {
    // CLEANROOM SM17
    return {};
}

bool SceneVertexArray::GetOption(std::string_view name) const {
    // CLEANROOM SM17
    (void)name;
    return false;
}
void SceneVertexArray::SetOption(std::string_view name, bool value) {
    // CLEANROOM SM17
    (void)name;
    (void)value;
}

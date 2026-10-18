#include "SceneIndexArray.h"
#include <cstring>
#include <utility>

using namespace wallpaper;

namespace
{
uint32_t* AllocateSlots(usize slots) {
    if (slots == 0) return nullptr;
    auto* data = new uint32_t[slots];
    std::memset(data, 0, slots * sizeof(uint32_t));
    return data;
}

bool QuadSlots(usize quadCount, SceneIndexWidth width, usize& slots) {
    const uint64_t per_quad = width == SceneIndexWidth::UInt32 ? 6ull : 3ull;
    uint64_t       count    = 0;
    if (! CheckedMulU64(quadCount, per_quad, count) ||
        count > std::numeric_limits<usize>::max() ||
        count > std::numeric_limits<usize>::max() / sizeof(uint32_t)) {
        return false;
    }
    slots = static_cast<usize>(count);
    return true;
}
} // namespace

SceneIndexArray::SceneIndexArray(std::size_t indexCount)
    : SceneIndexArray(indexCount, SceneIndexWidth::UInt16) {}

SceneIndexArray::SceneIndexArray(std::size_t quadCount, SceneIndexWidth width)
    : m_pData(nullptr), m_size(0), m_capacity(0), m_width(width) {
    usize slots = 0;
    if (! QuadSlots(quadCount, width, slots)) return;
    m_capacity = slots;
    m_pData    = AllocateSlots(slots);
}

SceneIndexArray::SceneIndexArray(std::span<const uint32_t> data) {
    // CLEANROOM SM18
    (void)data;
}
SceneIndexArray::SceneIndexArray(SceneIndexArray&& o) noexcept {
    // CLEANROOM SM18
    (void)o;
}

SceneIndexArray::~SceneIndexArray() {
    // CLEANROOM SM18
}

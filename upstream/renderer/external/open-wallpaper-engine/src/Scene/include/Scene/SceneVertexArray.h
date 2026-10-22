// Clean-room implementation from the WallpaperMachine spec e1b-scene-model.md; written without access to the original source.
#pragma once
#include <vector>
#include <string>
#include <cstddef>
#include <string_view>
#include <span>
#include <memory>
#include "Core/MapSet.hpp"

#include "Core/Literals.hpp"
#include "Core/NoCopyMove.hpp"
#include "Type.hpp"

namespace wallpaper
{

class SceneVertexArray : NoCopy {
public:
    struct SceneVertexAttribute {
        std::string name;
        VertexType  type;
        bool        padding { true };
    };
    struct SceneVertexAttributeOffset {
        SceneVertexAttribute attr;
        usize                offset;
    };

    // R1-S17: to be written from spec
    usize        OneSize() const { return m_stride; }
    usize        OneSizeOf() const { return m_stride * sizeof(float); }

    const auto&                                  Attributes() const { return m_attrs; }
    Map<std::string, SceneVertexAttributeOffset> GetAttrOffsetMap() const;

    uint32_t ID() const { return m_id; }
    void     SetID(uint32_t id) { m_id = id; }

    static uint8_t TypeCount(VertexType);
    static uint8_t RealAttributeSize(const SceneVertexAttribute&);

private:
    std::vector<SceneVertexAttribute> m_attrs;
    usize                             m_stride { 0 };   // words per vertex
    usize                             m_capacity { 0 }; // words
    usize                             m_size { 0 };     // words filled
    std::unique_ptr<float[]>          m_data;
    Map<std::string, bool>            m_options;
    uint32_t                          m_id { 0 };
};
} // namespace wallpaper

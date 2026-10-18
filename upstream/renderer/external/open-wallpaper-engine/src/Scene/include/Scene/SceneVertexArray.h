#pragma once
#include <vector>
#include <string>
#include <cstddef>
#include <string_view>
#include <span>
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

    SceneVertexArray(const std::vector<SceneVertexAttribute>& attrs, const std::size_t count);
    ~SceneVertexArray();

    SceneVertexArray(SceneVertexArray&&) noexcept;
    SceneVertexArray& operator=(SceneVertexArray&&) noexcept;

    bool AddVertex(const float*);
    bool SetVertex(std::string_view name, std::span<const float> data) noexcept;
    bool SetVertexs(std::size_t index, std::span<const float> data) noexcept;

    bool GetOption(std::string_view) const;
    void SetOption(std::string_view, bool);

    const float* Data() const {
        // CLEANROOM SM16
        return nullptr;
    }
    usize        DataSize() const {
        // CLEANROOM SM16
        return 0;
    }
    usize        DataSizeOf() const {
        // CLEANROOM SM16
        return 0;
    }
    usize        VertexCount() const {
        // CLEANROOM SM16
        return 0;
    }
    usize        CapacitySize() const {
        // CLEANROOM SM16
        return 0;
    }
    usize        CapacitySizeOf() const {
        // CLEANROOM SM16
        return 0;
    }
    usize        OneSize() const {
        // CLEANROOM SM16
        return 0;
    }
    usize        OneSizeOf() const {
        // CLEANROOM SM16
        return 0;
    }

    const auto&                                  Attributes() const {
        // CLEANROOM SM17
        static const std::vector<SceneVertexAttribute> none;
        return none;
    }
    Map<std::string, SceneVertexAttributeOffset> GetAttrOffsetMap() const;

    uint32_t ID() const {
        // CLEANROOM SM16
        return 0;
    }
    void     SetID(uint32_t id) {
        // CLEANROOM SM16
        (void)id;
    }

    static uint8_t TypeCount(VertexType);
    static uint8_t RealAttributeSize(const SceneVertexAttribute&);
};
} // namespace wallpaper

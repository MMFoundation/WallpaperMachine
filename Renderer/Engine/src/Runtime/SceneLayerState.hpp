#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace wallpaper {

struct SceneLayerState {
    static constexpr std::size_t MaxBytes = 64 * 1024;
    static constexpr std::size_t MaxLayers = 2048;
    static constexpr std::string_view EmptyJson = R"({"version":1,"layers":[]})";

    struct Layer {
        int32_t id;
        std::optional<bool> visible;
        std::optional<float> alpha;
    };
    std::span<const Layer> layers() const { return m_layers; }
    static std::optional<SceneLayerState> Parse(std::string_view text);

private:
    SceneLayerState() = default;
    std::vector<Layer> m_layers;
};

} // namespace wallpaper

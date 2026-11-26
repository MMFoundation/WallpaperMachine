#include "Runtime/SceneLayerState.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/SceneNode.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

namespace wallpaper {

std::optional<SceneLayerState> SceneLayerState::Parse(std::string_view text) {
    if (text.empty() || text.size() > MaxBytes || text.find('\0') != text.npos) return std::nullopt;
    using Json = nlohmann::json;
    bool version = false, layers = false, valid = true;
    const auto root = Json::parse(text, [&](int depth, Json::parse_event_t event, Json& value) {
        if (depth > 3) valid = false;
        if (event == Json::parse_event_t::key) {
            if (depth != 1) valid = false;
            else if (value == "version" && !version) version = true;
            else if (value == "layers" && !layers) layers = true;
            else valid = false;
        }
        return valid;
    }, false);
    if (!valid || !version || !layers || !root.is_object() ||
        !root["version"].is_number_integer() || root["version"] != 1) return std::nullopt;
    const auto& rows = root["layers"];
    if (!rows.is_array() || rows.size() > MaxLayers) return std::nullopt;
    SceneLayerState state;
    state.m_layers.reserve(rows.size());
    for (const auto& row : rows) {
        if (!row.is_array() || row.size() != 3) return std::nullopt;
        const auto& id = row[0];
        if (!id.is_number_integer() ||
            (id.is_number_unsigned() && id.get<uint64_t>() > std::numeric_limits<int32_t>::max()))
            return std::nullopt;
        const auto number = id.get<int64_t>();
        if (number == 0 || number < std::numeric_limits<int32_t>::min() ||
            number > std::numeric_limits<int32_t>::max()) return std::nullopt;
        Layer layer { .id = static_cast<int32_t>(number) };
        if (!row[1].is_null()) {
            if (!row[1].is_boolean()) return std::nullopt;
            layer.visible = row[1].get<bool>();
        }
        if (!row[2].is_null()) {
            if (!row[2].is_number()) return std::nullopt;
            const auto alpha = row[2].get<double>();
            if (!std::isfinite(alpha) || std::abs(alpha) > std::numeric_limits<float>::max())
                return std::nullopt;
            layer.alpha = static_cast<float>(alpha);
        }
        if (!layer.visible && !layer.alpha) return std::nullopt;
        state.m_layers.push_back(layer);
    }
    std::ranges::sort(state.m_layers, {}, &Layer::id);
    if (std::ranges::adjacent_find(state.m_layers, {}, &Layer::id) != state.m_layers.end())
        return std::nullopt;
    return state;
}

std::string SceneRuntimeContext::CaptureLayerState() const {
    if (!m_has_interactive_layer_state) return std::string(SceneLayerState::EmptyJson);
    using Json = nlohmann::json;
    auto rows = Json::array();
    for (const auto& [id, key] : m_layer_ids) {
        const auto node = m_nodes.find(key);
        if (node == m_nodes.end() || m_script_created_layers.contains(key)) continue;
        const bool visible = node->second->HasInteractiveVisibility();
        const auto alpha = m_node_alpha.find(key);
        const bool include_alpha = alpha != m_node_alpha.end() && alpha->second.interactive;
        if (!visible && !include_alpha) continue;
        if (rows.size() == SceneLayerState::MaxLayers ||
            (include_alpha && !std::isfinite(alpha->second.value))) return {};
        rows.push_back({ id, visible ? Json(node->second->Visible()) : Json(nullptr),
                         include_alpha ? Json(alpha->second.value) : Json(nullptr) });
    }
    if (rows.empty()) return std::string(SceneLayerState::EmptyJson);
    std::sort(rows.begin(), rows.end(), [](const Json& a, const Json& b) { return a[0] < b[0]; });
    auto text = Json({{"version", 1}, {"layers", std::move(rows)}}).dump();
    if (text.size() > SceneLayerState::MaxBytes) return {};
    return text;
}

std::optional<bool> SceneRuntimeContext::ApplyLayerState(const SceneLayerState& state) {
    for (const auto& layer : state.layers()) {
        const auto name = m_layer_ids.find(layer.id);
        if (name == m_layer_ids.end() || !m_nodes.contains(name->second) ||
            m_script_created_layers.contains(name->second)) return std::nullopt;
        if (layer.alpha) {
            const auto current = NodeAlpha(name->second);
            if (!current || !std::isfinite(*current)) return std::nullopt;
        }
    }
    bool changed = false;
    const auto apply_field = [&]<typename T>(std::optional<T> wanted, std::optional<ImportedValue<T>> old,
                                             T current, auto write) -> std::optional<ImportedValue<T>> {
        const bool owned = old && old->applied == current;
        if (!wanted && !owned) return std::nullopt;
        const T original = owned ? old->original : current;
        const T value = wanted.value_or(original);
        if (value != current) {
            write(value);
            changed = true;
        }
        if (value == original) return std::nullopt;
        return ImportedValue<T> { original, value };
    };
    const auto incoming = state.layers();
    std::vector<ImportedLayer> next;
    auto wanted = incoming.begin();
    auto prior = m_imported_layers.begin();
    while (wanted != incoming.end() || prior != m_imported_layers.end()) {
        const int32_t id = prior == m_imported_layers.end() ? wanted->id :
                           wanted == incoming.end() ? prior->id : std::min(wanted->id, prior->id);
        const auto row = wanted != incoming.end() && wanted->id == id ? *wanted++
                                                                      : SceneLayerState::Layer { .id = id };
        const auto old = prior != m_imported_layers.end() && prior->id == id ? *prior++
                                                                             : ImportedLayer { .id = id };
        const auto found = m_layer_ids.find(id);
        if (found == m_layer_ids.end() || m_script_created_layers.contains(found->second)) continue;
        const auto& key = found->second;
        ImportedLayer held { .id = id };
        if (row.visible || old.visible) {
            held.visible = apply_field(row.visible, old.visible, NodeVisible(key),
                                       [&](bool value) { SetNodeVisible(key, value); });
        }
        if (row.alpha || old.alpha) {
            if (const auto current = NodeAlpha(key)) {
                held.alpha = apply_field(row.alpha, old.alpha, *current,
                                         [&](float value) { SetNodeAlpha(key, value); });
            }
        }
        if (held.visible || held.alpha) next.push_back(held);
    }
    m_imported_layers = std::move(next);
    return changed;
}

} // namespace wallpaper

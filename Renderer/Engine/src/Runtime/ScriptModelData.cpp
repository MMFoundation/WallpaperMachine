#include "Runtime/ScriptModelData.hpp"

#include "Scene/include/Scene/SceneMesh.h"
#include "SpecTexs.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>

namespace wallpaper
{
namespace
{
struct ComponentInfo {
    std::string_view word;
    std::string_view attribute;
    VertexType       type;
    std::size_t      floats;
};

// Wallpaper Engine's vertex format flags, in the only order a format may list them.
constexpr std::array<ComponentInfo, 5> kComponents { {
    { "position", WE_IN_POSITION, VertexType::FLOAT3, 3 },
    { "normal", WE_IN_NORMAL, VertexType::FLOAT3, 3 },
    { "tangentSigned", WE_IN_TANGENT, VertexType::FLOAT4, 4 },
    { "uv", WE_IN_TEXCOORD, VertexType::FLOAT2, 2 },
    { "color", WE_IN_COLOR, VertexType::FLOAT4, 4 },
} };

const ComponentInfo* FindComponent(std::string_view word, std::size_t& order) {
    for (order = 0; order < kComponents.size(); ++order) {
        if (kComponents[order].word == word) return &kComponents[order];
    }
    return nullptr;
}

// Whether every index names one of `vertices` vertices.
bool IndicesInRange(const ScriptIndexBuffer& indices, std::size_t vertices) {
    for (std::size_t i = 0; i < indices.count; ++i) {
        const uint32_t index = indices.wide ? static_cast<const uint32_t*>(indices.data)[i]
                                            : static_cast<const uint16_t*>(indices.data)[i];
        if (index >= vertices) return false;
    }
    return true;
}

// Indices are kept 32 bits wide whatever the script passed, so a count that is not even
// needs no packing rule.
void WriteIndices(SceneIndexArray& array, const ScriptIndexBuffer& indices) {
    if (indices.wide) {
        array.Assign(0, std::span<const uint32_t>(static_cast<const uint32_t*>(indices.data), indices.count));
    } else {
        std::vector<uint32_t> wide(indices.count);
        const auto*           narrow = static_cast<const uint16_t*>(indices.data);
        std::copy(narrow, narrow + indices.count, wide.begin());
        array.Assign(0, wide);
    }
    array.SetDrawIndexCount(indices.count);
}
} // namespace

bool ScriptModelData::Component(std::string_view word, std::string& attribute, std::size_t& floats) {
    std::size_t order = 0;
    const auto* found = FindComponent(word, order);
    if (found == nullptr) return false;
    attribute = std::string(found->attribute);
    floats    = found->floats;
    return true;
}

std::shared_ptr<ScriptModelData> ScriptModelData::Build(std::span<const ScriptModelShapeInput> shapes,
                                                        std::string&                           error) {
    if (shapes.empty()) {
        error = "createModelData needs at least one shape";
        return nullptr;
    }
    auto model        = std::shared_ptr<ScriptModelData>(new ScriptModelData());
    model->m_geometry = std::make_shared<SceneMesh>();
    auto& submeshes   = model->m_geometry->Submeshes();
    for (std::size_t s = 0; s < shapes.size(); ++s) {
        const auto& input = shapes[s];
        const std::string where = "shape " + std::to_string(s) + ": ";

        static const std::vector<std::string> kDefaultFormat { "position", "normal", "uv" };
        const auto& format = input.format.empty() ? kDefaultFormat : input.format;
        std::vector<SceneVertexArray::SceneVertexAttribute> attributes;
        std::size_t                                         stride = 0;
        std::size_t                                         last   = 0;
        for (const auto& word : format) {
            std::size_t order = 0;
            const auto* component = FindComponent(word, order);
            if (component == nullptr) {
                error = where + "unknown vertex format flag '" + word + "'";
                return nullptr;
            }
            if (! attributes.empty() && order <= last) {
                error = where + "the vertex format must list POSITION, NORMAL, TANGENT_SIGNED, UV, COLOR in that order";
                return nullptr;
            }
            last = order;
            // Packed as the script packs its buffer: no component is padded to four floats.
            attributes.push_back({ std::string(component->attribute), component->type, false });
            stride += component->floats;
        }
        if (! input.has_vertices || input.vertices.empty() || input.vertices.size() % stride != 0) {
            error = where + "the vertex buffer must hold whole vertices of " + std::to_string(stride) + " floats";
            return nullptr;
        }
        const std::size_t vertex_count = input.vertices.size() / stride;
        if (input.has_indices && (input.indices.count == 0 || ! IndicesInRange(input.indices, vertex_count))) {
            error = where + "the index buffer is empty or names a vertex the vertex buffer does not hold";
            return nullptr;
        }

        auto& submesh = submeshes.emplace_back();
        SceneVertexArray vertices(attributes, vertex_count);
        if (vertices.CapacitySize() != input.vertices.size() || ! vertices.SetVertexs(0, input.vertices)) {
            error = where + "the vertex buffer is too large";
            submeshes.pop_back();
            return nullptr;
        }
        submesh.AddVertexArray(std::move(vertices));
        if (input.has_indices) {
            SceneIndexArray indices((input.indices.count + 5) / 6, SceneIndexWidth::UInt32);
            WriteIndices(indices, input.indices);
            submesh.AddIndexArray(std::move(indices));
        }
        submesh.material_slot = static_cast<uint32_t>(s);

        Shape shape;
        shape.material         = input.material;
        shape.vertex_floats    = input.vertices.size();
        shape.indexed          = input.has_indices;
        shape.index_count      = input.has_indices ? input.indices.count : 0;
        shape.dynamic_vertices = input.dynamic_vertices;
        shape.dynamic_indices  = input.dynamic_indices && input.has_indices;
        model->m_shapes.push_back(std::move(shape));
        model->m_bytes += input.vertices.size() * sizeof(float) + model->m_shapes.back().index_count * sizeof(uint32_t);
    }
    return model;
}

std::string ScriptModelData::Apply(std::size_t index, const ScriptModelShapeInput& input) {
    if (index >= m_shapes.size()) return "applyData names shape " + std::to_string(index) + ", which the model does not have";
    const Shape& shape   = m_shapes[index];
    auto&        submesh = m_geometry->Submeshes()[index];
    if (input.has_vertices) {
        if (! shape.dynamic_vertices) return "applyData: the vertex buffer was not created with isVertexBufferDynamic";
        if (input.vertices.size() != shape.vertex_floats) return "applyData: the vertex buffer must keep its length";
    }
    if (input.has_indices) {
        if (! shape.dynamic_indices) return "applyData: the index buffer was not created with isIndexBufferDynamic";
        if (input.indices.count != shape.index_count) return "applyData: the index buffer must keep its length";
        const std::size_t vertices = submesh.GetVertexArray(0).VertexCount();
        if (! IndicesInRange(input.indices, vertices)) return "applyData: an index names a vertex the vertex buffer does not hold";
    }
    if (! input.has_vertices && ! input.has_indices) return {};
    if (input.has_vertices) submesh.GetVertexArray(0).SetVertexs(0, input.vertices);
    if (input.has_indices) WriteIndices(submesh.GetIndexArray(0), input.indices);
    std::erase_if(m_users, [](const std::weak_ptr<SceneMesh>& user) {
        const auto mesh = user.lock();
        if (mesh == nullptr) return true;
        mesh->SetDirty();
        return false;
    });
    return {};
}

bool ScriptModelData::Dynamic() const {
    return std::any_of(m_shapes.begin(), m_shapes.end(),
                       [](const Shape& shape) { return shape.dynamic_vertices || shape.dynamic_indices; });
}

void ScriptModelData::AddUser(const std::shared_ptr<SceneMesh>& mesh) {
    std::erase_if(m_users, [](const std::weak_ptr<SceneMesh>& user) { return user.expired(); });
    m_users.push_back(mesh);
}

} // namespace wallpaper

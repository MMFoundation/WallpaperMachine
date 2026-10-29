#pragma once
// Geometry a scene script builds with `thisScene.createModelData` (Wallpaper Engine's
// IModelData): one submesh per shape, laid out exactly as the script's Float32Array, and
// the materials the shapes name. Layers made from it (`createLayer({ model })`) share the
// geometry; `applyData` rewrites it in place and marks every such layer's mesh changed, so
// the renderer copies it once and nothing is uploaded on a frame the script changed nothing.

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace wallpaper
{
class SceneMesh;

/// An index buffer a script hands over: a Uint16Array or a Uint32Array.
struct ScriptIndexBuffer {
    const void* data { nullptr };
    std::size_t count { 0 };
    bool        wide { false };
};

/// One shape of `createModelData` or `applyData`, borrowed from the script for the call.
struct ScriptModelShapeInput {
    /// The IModelData words in order (`position`, `normal`, `tangentSigned`, `uv`, `color`);
    /// empty for the default format, POSITION | NORMAL | UV.
    std::vector<std::string>          format;
    bool                              has_vertices { false };
    std::span<const float>            vertices;
    bool                              has_indices { false };
    ScriptIndexBuffer                 indices;
    std::string                       material;
    bool                              dynamic_vertices { false };
    bool                              dynamic_indices { false };
};

class ScriptModelData {
public:
    struct Shape {
        std::string material;
        std::size_t vertex_floats { 0 };
        std::size_t index_count { 0 };
        bool        indexed { false };
        bool        dynamic_vertices { false };
        bool        dynamic_indices { false };
    };

    /// Builds the geometry, or returns null with `error` saying what the script got wrong.
    static std::shared_ptr<ScriptModelData> Build(std::span<const ScriptModelShapeInput> shapes,
                                                  std::string&                           error);

    /// `applyData` for shape `index`: copies the buffers the input carries over the ones the
    /// shape holds. Empty on success, else the error the script throws.
    std::string Apply(std::size_t index, const ScriptModelShapeInput& input);

    /// The geometry a layer's mesh shares (`SceneMesh::ChangeMeshDataFrom`).
    const SceneMesh& Geometry() const { return *m_geometry; }
    const std::vector<Shape>& Shapes() const { return m_shapes; }
    /// Whether a layer's mesh must be uploaded through the dynamic path.
    bool Dynamic() const;
    /// The bytes the geometry holds, for the bound on what scripts may keep alive.
    std::size_t Bytes() const { return m_bytes; }

    /// A layer's mesh drawing this geometry: told when `Apply` changes it.
    void AddUser(const std::shared_ptr<SceneMesh>& mesh);

    /// The vertex attribute name and float count of an IModelData word; false for a word
    /// that is none of them.
    static bool Component(std::string_view word, std::string& attribute, std::size_t& floats);

private:
    std::shared_ptr<SceneMesh>            m_geometry;
    std::vector<Shape>                    m_shapes;
    std::vector<std::weak_ptr<SceneMesh>> m_users;
    std::size_t                           m_bytes { 0 };
};

} // namespace wallpaper

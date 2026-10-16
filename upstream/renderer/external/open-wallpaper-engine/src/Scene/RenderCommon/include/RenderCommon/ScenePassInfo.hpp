#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace wallpaper
{

class SceneNode;

/// What a clear step does, as the scene sees it: the target it clears and
/// whether it clears to nothing rather than to the scene's background.
struct ClearPassInfo {
    const std::string& result;
    bool               transparent;
};

/// What a copy step does: the target it reads and the one it writes.
struct CopyPassInfo {
    const std::string& src;
    const std::string& dst;
};

/// What a draw step does, as the scene sees it: the node and submesh it
/// draws, the targets it samples and writes, and how it loads its target. It
/// carries nothing about how a particular backend records the draw.
struct DrawPassInfo {
    SceneNode*                      node;
    SceneNode*                      visibility_node;
    const std::vector<std::string>& textures;
    const std::string&              output;
    const std::string&              camera_override;
    std::size_t                     submesh_index;
    uint32_t                        material_slot;
    bool                            clear_on_first_use;
    bool                            preserve_target_contents;
    bool                            write_alpha;
};

/// The read-only description of one render-graph step that every backend can
/// consume. A backend's own pass objects implement it next to their executable
/// code, and a renderer that draws the graph a different way reads the steps
/// through it, so it never has to name another backend's pass classes. A
/// description is a view into the pass: it is valid while the pass is.
///
/// A step answers for exactly one kind; the others return nothing, which is
/// how a caller tells a step that is not the kind its graph node claims.
class ScenePassInfo {
public:
    virtual ~ScenePassInfo();

    virtual std::optional<ClearPassInfo> clearInfo() const { return std::nullopt; }
    virtual std::optional<CopyPassInfo>  copyInfo() const { return std::nullopt; }
    virtual std::optional<DrawPassInfo>  drawInfo() const { return std::nullopt; }
};

} // namespace wallpaper

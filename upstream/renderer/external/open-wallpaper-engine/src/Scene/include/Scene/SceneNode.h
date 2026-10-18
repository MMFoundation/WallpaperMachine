#pragma once
#include <list>
#include <vector>
#include <memory>
#include <optional>
#include <utility>
#include "Utils/Linalg.hpp"
#include "SceneMesh.h"
#include "SceneCamera.h"

#include "Core/Literals.hpp"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{

class SceneNode : NoCopy, NoMove {
public:
    SceneNode() {
        // CLEANROOM SM5
    }
    SceneNode(const linalg::Vector3f& translate, const linalg::Vector3f& scale,
              const linalg::Vector3f& rotation, const std::string& name = "") {
        // CLEANROOM SM5
        (void)translate;
        (void)scale;
        (void)rotation;
        (void)name;
    }

    const auto& Camera() const {
        // CLEANROOM SM6
        static const std::string none;
        return none;
    }
    void SetCamera(const std::string& name) {
        // CLEANROOM SM6
        (void)name;
    }
    void AddMesh(std::shared_ptr<SceneMesh> mesh) {
        // CLEANROOM SM6
        (void)mesh;
    }
    void AppendChild(std::shared_ptr<SceneNode> sub) {
        // CLEANROOM SM6
        (void)sub;
    }
    linalg::Matrix4d GetLocalTrans() const;
    static linalg::Matrix4d LocalTransOf(const linalg::Vector3f& translate,
                                        const linalg::Vector3f& scale,
                                        const linalg::Vector3f& rotation);

    const auto& Translate() const {
        // CLEANROOM SM7
        static const linalg::Vector3f none = linalg::Vector3f::Zero();
        return none;
    }
    const auto& Scale() const {
        // CLEANROOM SM7
        static const linalg::Vector3f none { 1.0f, 1.0f, 1.0f };
        return none;
    }
    const auto& Rotation() const {
        // CLEANROOM SM7
        static const linalg::Vector3f none = linalg::Vector3f::Zero();
        return none;
    }
    const auto& Name() const {
        // CLEANROOM SM6
        static const std::string none;
        return none;
    }
    void SetName(std::string name) {
        // CLEANROOM SM6
        (void)name;
    }
    bool Visible() const {
        // CLEANROOM SM8
        return true;
    }
    bool SkipRenderPass() const {
        // CLEANROOM SM8
        return false;
    }
    /// A frame a script pinned the sprite sheet to; the sheet holds it until
    /// `ClearTextureFrame` (a script's `play()`) lets it run again.
    const auto& TextureFrame() const {
        // CLEANROOM SM8
        static const std::optional<double> none;
        return none;
    }
    void SetTextureFrame(double frame) {
        // CLEANROOM SM8
        (void)frame;
    }
    void ClearTextureFrame() { m_textureFrame.reset(); }
    /// What a script's `pause()`, `stop()`, `play()` and `rate` say about the
    /// sprite sheet the layer draws. The renderer advances the sheet by the
    /// frame time scaled by `TextureAnimationStep`, which is zero while paused,
    /// so a paused sheet holds the frame it is on.
    bool   TextureAnimationPaused() const { return m_textureAnimationPaused; }
    void   SetTextureAnimationPaused(bool paused) { m_textureAnimationPaused = paused; }
    /// The rate a script set, as it set it: `rate` reads back what was written.
    double TextureAnimationRate() const { return m_textureAnimationRate; }
    void   SetTextureAnimationRate(double rate) { m_textureAnimationRate = rate; }
    /// How far the sheet advances in `frame_time`: nothing while paused, or at a
    /// rate that is not a positive speed a sheet could show. That range is
    /// applied here, where the rate is used, and not to the value stored.
    double TextureAnimationStep(double frame_time) const {
        const bool usable = m_textureAnimationRate > 0.0 && m_textureAnimationRate < 1.0e6;
        return m_textureAnimationPaused || ! usable ? 0.0 : frame_time * m_textureAnimationRate;
    }
    /// The sheet frame the renderer last drew, for a script that asks where the
    /// animation is. Absent until a frame has drawn it.
    const auto& TextureAnimationFrame() const { return m_textureAnimationFrame; }
    void SetTextureAnimationFrame(double frame) { m_textureAnimationFrame = frame; }
    bool        MustProduce() const { return m_must_produce; }
    void        SetMustProduce(bool produce) { m_must_produce = produce; }
    /// Drawn only into its own composite, which another layer samples; never
    /// onto the scene. A compose layer copying the background behind it is
    /// this: on screen it would change nothing, but its card is that background.
    bool        CompositeOnly() const { return m_composite_only; }
    void        SetCompositeOnly(bool only) { m_composite_only = only; }
    bool        EffectiveVisible() const {
        // CLEANROOM SM8
        return true;
    }
    /// Visibility only a reload changes: an authored value or one of the
    /// wallpaper's own properties, which reparse the scene when they change.
    /// False for a script-driven layer and from the moment a script writes
    /// this one's visibility, since from then on the script decides.
    bool        VisibilitySettled() const { return m_visibility_settled; }
    void        SetVisibilitySettled(bool settled) { m_visibility_settled = settled; }
    void        SetRotation(linalg::Vector3f v) {
        // CLEANROOM SM7
        (void)v;
    }
    void        SetTranslate(linalg::Vector3f v) {
        // CLEANROOM SM7
        (void)v;
    }
    void        SetScale(linalg::Vector3f v) {
        // CLEANROOM SM7
        (void)v;
    }
    void        SetVisible(bool visible) {
        // CLEANROOM SM8
        (void)visible;
    }
    void        SetSkipRenderPass(bool skip) {
        // CLEANROOM SM8
        (void)skip;
    }
    /// A node placed by its own transform alone, whatever its ancestors do: a
    /// fullscreen layer covers the screen from whichever group it sits in.
    /// The hierarchy above it still decides whether it shows (`EffectiveVisible`),
    /// but no longer where it is, how large or how turned.
    bool        IgnoresParentTransform() const { return m_ignoreParentTransform; }
    void        SetIgnoreParentTransform(bool ignore) {
        if (m_ignoreParentTransform == ignore) return;
        m_ignoreParentTransform = ignore;
        MarkTransDirty();
    }

    /// Where the node's children are placed from, for a node drawn by something
    /// other than its own transform. A fullscreen layer covers the screen
    /// whatever its origin, scale or angles, but the layers below it are placed
    /// from the transform the scene saved for it (none saved, none added), under
    /// whatever groups it sits in. Without one a child is placed from the node's
    /// own `ModelTrans`.
    void SetChildFrame(const linalg::Vector3f& translate, const linalg::Vector3f& scale,
                       const linalg::Vector3f& rotation) {
        m_childLocal = LocalTransOf(translate, scale, rotation);
        MarkTransDirty();
    }
    bool HasChildFrame() const { return m_childLocal.has_value(); }
    /// Takes over another node's child frame, as a copy of the node does.
    void CopyChildFrame(const SceneNode& node) {
        if (m_childLocal == node.m_childLocal) return;
        m_childLocal = node.m_childLocal;
        MarkTransDirty();
    }

    void SetAttachmentTransform(const linalg::Matrix4d& transform) {
        if (m_attachmentTransform && m_attachmentTransform->isApprox(transform, 1.0e-10)) return;
        m_attachmentTransform = transform;
        MarkTransDirty();
    }

    void CopyTrans(const SceneNode& node) {
        // CLEANROOM SM7
        (void)node;
    }

    void SetRenderTransformOverride(linalg::Matrix4d transform) {
        // CLEANROOM SM7
        (void)transform;
    }
    void ClearRenderTransformOverride() {
        // CLEANROOM SM7
    }
    bool HasRenderTransformOverride() const {
        // CLEANROOM SM7
        return false;
    }
    /// A translation in world space added to where the node is drawn and to nothing
    /// else. `RenderTrans` carries it; `ModelTrans`, which the node's children, its
    /// cameras and its hit test compose from, does not (a hit test adds it itself).
    /// A node drawn through a `RenderTransformOverride` draws where that says, which
    /// is a whole matrix already.
    void SetDrawOffset(const linalg::Vector3f& offset) { m_drawOffset = offset; }
    const linalg::Vector3f& DrawOffset() const { return m_drawOffset; }
    linalg::Matrix4d RenderTrans() const {
        if (m_renderTransformOverride) return *m_renderTransformOverride;
        if (m_drawOffset.isZero()) return m_trans;
        linalg::Matrix4d moved = m_trans;
        moved.block<3, 1>(0, 3) += m_drawOffset.cast<double>();
        return moved;
    }

    void            UpdateTrans();
    linalg::Matrix4d ModelTrans() const { return m_trans; };
    /// The matrix the children's own are composed on (after `UpdateTrans`).
    linalg::Matrix4d ChildTrans() const { return m_childTrans; }

    SceneMesh* Mesh() {
        // CLEANROOM SM6
        return nullptr;
    }
    bool       HasMaterial() const {
        // CLEANROOM SM6
        return false;
    };

    const auto& GetChildren() const {
        // CLEANROOM SM6
        static const std::list<std::shared_ptr<SceneNode>> none;
        return none;
    }
    auto&       GetChildren() {
        // CLEANROOM SM6
        static std::list<std::shared_ptr<SceneNode>> none;
        none.clear();
        return none;
    }
    SceneNode*  Parent() const {
        // CLEANROOM SM6
        return nullptr;
    }
    bool        NodeHasParent() const {
        // CLEANROOM SM6
        return false;
    }

    i32& ID() {
        // CLEANROOM SM6
        static i32 none = 0;
        return none;
    }

private:
    void MarkTransDirty();

    bool        m_ignoreParentTransform { false };
    bool        m_must_produce { false };
    bool        m_composite_only { false };
    bool        m_visibility_settled { false };
    std::optional<double> m_textureFrame;
    bool                  m_textureAnimationPaused { false };
    double                m_textureAnimationRate { 1.0 };
    std::optional<double> m_textureAnimationFrame;

    linalg::Matrix4d m_trans { linalg::Matrix4d::Identity() };
    linalg::Matrix4d m_childTrans { linalg::Matrix4d::Identity() };
    std::optional<linalg::Matrix4d> m_childLocal;

    linalg::Vector3f m_translate { 0.0f, 0.0f, 0.0f };
    linalg::Vector3f m_scale { 1.0f, 1.0f, 1.0f };
    linalg::Vector3f m_rotation { 0.0f, 0.0f, 0.0f };
    std::optional<linalg::Matrix4d> m_renderTransformOverride {};
    linalg::Vector3f m_drawOffset { 0.0f, 0.0f, 0.0f };
    std::optional<linalg::Matrix4d> m_attachmentTransform;
};
} // namespace wallpaper

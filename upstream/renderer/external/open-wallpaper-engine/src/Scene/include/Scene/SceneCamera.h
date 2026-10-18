#pragma once
#include <cstdint>
#include <cmath>
#include <vector>
#include <memory>
#include <optional>
#include "Utils/Linalg.hpp"
#include "SceneImageEffectLayer.h"

namespace wallpaper
{

class SceneNode;

class SceneCamera {
public:
    explicit SceneCamera(i32 width, i32 height, float near, float far) {
        // CLEANROOM SM9
        (void)width;
        (void)height;
        (void)near;
        (void)far;
    }

    explicit SceneCamera(float aspect, float near, float far, float fov) {
        // CLEANROOM SM9
        (void)aspect;
        (void)near;
        (void)far;
        (void)fov;
    }

    SceneCamera(const SceneCamera&) = default;

    void Update();

    void AttatchNode(std::shared_ptr<SceneNode>);

    bool   IsPerspective() const {
        // CLEANROOM SM9
        return false;
    }
    double Aspect() const {
        // CLEANROOM SM9
        return 0.0;
    }
    double Width() const {
        // CLEANROOM SM9
        return 0.0;
    }
    double Height() const {
        // CLEANROOM SM9
        return 0.0;
    }
    double NearClip() const {
        // CLEANROOM SM9
        return 0.0;
    }
    double FarClip() const {
        // CLEANROOM SM9
        return 0.0;
    }
    double Fov() const {
        // CLEANROOM SM9
        return 0.0;
    }

    void SetWidth(double value) {
        // CLEANROOM SM9
        (void)value;
    }
    void SetHeight(double value) {
        // CLEANROOM SM9
        (void)value;
    }
    void SetAspect(double aspect) {
        // CLEANROOM SM9
        (void)aspect;
    }
    void SetFov(double value) {
        // CLEANROOM SM9
        (void)value;
    }
    /// The depth range a perspective projection keeps.
    void SetClip(double near_clip, double far_clip) {
        m_nearClip = near_clip;
        m_farClip  = far_clip;
    }
    /// A camera object's own zoom, separate from the scene-wide zoom that
    /// writes width and height. Larger zooms in; anything not positive and
    /// finite frames the full canvas.
    void   SetZoom(double value) { m_zoom = value; }
    double Zoom() const { return m_zoom; }
    /// The extent the orthographic projection actually shows. Pointer mapping
    /// reads this rather than the authored width and height: a click has to
    /// land where the zoomed image is, not where an unzoomed one would be.
    double VisibleWidth() const { return m_width / EffectiveZoom(); }
    double VisibleHeight() const { return m_height / EffectiveZoom(); }

    void  AttatchImgEffect(std::shared_ptr<SceneImageEffectLayer> eff) {
        // CLEANROOM SM10
        (void)eff;
    }
    bool  HasImgEffect() const {
        // CLEANROOM SM10
        return false;
    }
    auto& GetImgEffect() {
        // CLEANROOM SM10
        static std::shared_ptr<SceneImageEffectLayer> none;
        none.reset();
        return none;
    }
    void  SetComposeLayer(bool compose) {
        // CLEANROOM SM10
        (void)compose;
    }
    bool  IsComposeLayer() const {
        // CLEANROOM SM10
        return false;
    }
    /// A camera that frames one layer's card in that layer's own texture space:
    /// the card fills the target and nothing about where the layer sits in the
    /// scene -- its transform, the scene camera, parallax -- reaches the image.
    /// This is what another layer samples as `_rt_imageLayerComposite_<id>`.
    void  SetLayerLocal(bool layer_local) { m_layerLocal = layer_local; }
    bool  IsLayerLocal() const { return m_layerLocal; }
    /// A compose layer whose children are drawn through the scene's camera
    /// rather than this one: a fullscreen layer, which Wallpaper Engine gives no
    /// camera of its own, so the layers below it are zoomed, shaken and framed
    /// with the rest of the scene and land in its picture where they would land
    /// on screen.
    void  SetChildrenUseSceneCamera(bool scene) { m_childrenUseSceneCamera = scene; }
    bool  ChildrenUseSceneCamera() const { return m_childrenUseSceneCamera; }

    linalg::Vector3d GetPosition() const;
    linalg::Vector3d GetDirection() const;
    linalg::Vector3d GetUp() const;
    linalg::Vector3d GetRight() const;

    void LockFov(bool lock) { m_fovLocked = lock; }
    bool FovLocked() const { return m_fovLocked; }

    linalg::Matrix4d GetViewMatrix() const;
    linalg::Matrix4d GetViewProjectionMatrix() const;

    /// World-space axes of the attached node, which is the basis the particle
    /// shaders read as `g_Orientation*`. Identity when no node is attached,
    /// matching the constants the parser writes for an unrotated camera.
    struct Axes {
        linalg::Vector3d right { 1.0, 0.0, 0.0 };
        linalg::Vector3d up { 0.0, 1.0, 0.0 };
        linalg::Vector3d forward { 0.0, 0.0, 1.0 };
    };
    Axes GetAxes() const;

    std::shared_ptr<SceneNode> GetAttachedNode() const {
        // CLEANROOM SM10
        return nullptr;
    }

    /// Camera shake: moves the eye and what it looks at together, on top of
    /// wherever the camera's node puts them.
    void SetShakeOffset(const linalg::Vector3d& offset) { m_shake = offset; }
    const linalg::Vector3d& ShakeOffset() const { return m_shake; }

    void Clone(const SceneCamera& cam) {
        // CLEANROOM SM10
        (void)cam;
    }

private:
    // A zoom of zero, a negative one or a NaN is not a frame anybody can see,
    // so it reads as the whole canvas rather than as a division.
    double EffectiveZoom() const {
        return (std::isfinite(m_zoom) && m_zoom > 0.0) ? m_zoom : 1.0;
    }

    linalg::Vector3d m_shake { linalg::Vector3d::Zero() };
    double m_width { 1.0f };
    double m_height { 1.0f };
    double m_nearClip { 0.01f };
    double m_farClip { 1000.0f };
    double m_zoom { 1.0 };
    bool   m_fovLocked { false };

    std::shared_ptr<SceneNode>             m_node;
    bool                                   m_layerLocal { false };
    bool                                   m_childrenUseSceneCamera { false };
};

/// Seats the perspective camera of a 2D scene -- the one particles, models and
/// layers with the `perspective` flag draw through -- on the view `canvas`
/// shows, as Wallpaper Engine does. The eye sits (visible height / 2) /
/// tan(fov / 2) in front of the canvas plane, the near plane 5 units from the
/// eye and the far plane 1000 units behind the canvas plane or 15000 from the
/// eye, whichever is further. The field of view is the scene's and never
/// moves, so the canvas plane maps exactly as the orthographic view maps it,
/// whatever frames it (a fill mode, a zoom, a camera layer), and what lies off
/// the plane is magnified by D / (D - z) and stays in view up to the eye. Only
/// the depth moves: the caller aims the camera. A camera with a locked field of
/// view belongs to a perspective scene and is left alone. Call `Update`
/// afterwards.
void FitCanvasPerspective(SceneCamera& perspective, const SceneCamera& canvas);

/// How far in front of the canvas plane the eye is that shaders read as
/// `g_EyePosition` in a 2D scene. It is a constant of the scene -- 2000 units out
/// over the centre of the view -- and not the distance the perspective camera
/// sits at, which follows its field of view and the visible canvas. Particle
/// trails turn their ribbons by the angle between a particle and this eye.
inline constexpr float kCanvasShaderEyeDepth = 2000.0f;

/// Intersects the camera ray through NDC `(ndc_x, ndc_y)` with `node`'s local
/// z = 0 plane, where the node is drawn (its draw offset included). NDC is the
/// shared clip space after the perspective divide, x/y in [-1, 1], with this
/// engine's near = 0 and far = 1. Returns local coordinates on the plane, or
/// nullopt if the inverse is degenerate, the ray is parallel to the plane, or the
/// hit lies outside the clip volume.
[[nodiscard]] std::optional<linalg::Vector3d> IntersectNdcWithNodePlane(
    const SceneCamera& camera, SceneNode& node, double ndc_x, double ndc_y);

/// The world-space point on the camera ray through NDC `(ndc_x, ndc_y)` that is
/// `depth` in front of the eye, measured along the view axis (the camera's view
/// space z is `-depth`), the way `glm::unProject` puts a pointer at one depth of
/// the frustum. NDC x/y span the frustum in [-1, 1] as the projection does.
/// Perspective cameras only: nullopt for an orthographic one, for a depth that
/// is not positive and finite, or when the camera has no usable view.
[[nodiscard]] std::optional<linalg::Vector3d> UnprojectNdcAtDepth(const SceneCamera& camera,
                                                                 double ndc_x, double ndc_y,
                                                                 double depth);
} // namespace wallpaper

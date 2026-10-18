#include "SceneNode.h"

#include "Utils/Linalg.hpp"

using namespace wallpaper;
using namespace wallpaper::linalg;

Matrix4d SceneNode::LocalTransOf(const Vector3f& translate, const Vector3f& scale,
                                 const Vector3f& rotation) {
    // CLEANROOM SM7
    (void)translate;
    (void)scale;
    (void)rotation;
    return Matrix4d::Identity();
}

Matrix4d SceneNode::GetLocalTrans() const {
    const Matrix4d local = LocalTransOf(m_translate, m_scale, m_rotation);
    if (m_attachmentTransform) return *m_attachmentTransform * local;
    return local;
}

void SceneNode::UpdateTrans() {
    // CLEANROOM SM7
}

void SceneNode::MarkTransDirty() {
    // CLEANROOM SM7
}

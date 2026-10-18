#pragma once
#include <cstdint>
#include <vector>
#include <iostream>
#include <cstdint>
#include <array>
#include <algorithm>
#include <cmath>

#include "Core/Literals.hpp"

namespace wallpaper
{
struct SpriteFrame {
    i32   imageId { 0 };
    float frametime { 0 };
    float x { 0 };
    float y { 0 };
    float width { 1 };
    float height { 1 };
    float rate { 1 };

    std::array<float, 2> xAxis { 1, 0 };
    std::array<float, 2> yAxis { 0, 1 };
};

class SpriteAnimation {
public:
    const auto& GetAnimateFrame(double newtime) {
        // CLEANROOM UV17
        (void)newtime;
        static const SpriteFrame neutral {};
        return neutral;
    }
    const auto& SetFrame(double frame) {
        // CLEANROOM UV18
        (void)frame;
        static const SpriteFrame neutral {};
        return neutral;
    }
    const auto& GetCurFrame() const { return m_frames.at((usize)m_curFrame); }
    /// One frame by index, for callers that must know every image a sheet can
    /// reach before the animation reaches it -- a renderer that uploads the
    /// sheets up front cannot wait to be surprised mid-playback.
    const SpriteFrame& FrameAt(usize index) const { return m_frames.at(index); }
    /// Index of the frame `GetCurFrame` returns.
    idx CurFrameIndex() const { return m_curFrame; }
    /// A single-frame sprite never advances, so it does not make its pass
    /// time-varying.
    usize FrameCount() const { return m_frames.size(); }
    void        AppendFrame(const SpriteFrame& frame) { m_frames.push_back(frame); }

    usize numFrames() const { return m_frames.size(); }

private:
    static double FrameDuration(const SpriteFrame& frame) {
        return std::isfinite(frame.frametime) && frame.frametime > 0.0f ? frame.frametime : 0.0;
    }
    idx    m_curFrame { 0 };
    double m_remainTime { 0 };

    std::vector<SpriteFrame> m_frames;
};
} // namespace wallpaper

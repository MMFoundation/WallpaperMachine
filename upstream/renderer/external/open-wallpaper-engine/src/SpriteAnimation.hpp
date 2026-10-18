// Clean-room implementation from the WallpaperMachine spec e7-small-units.md; written without access to the original source.
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
        // A sheet without frames is not a sprite sheet; there is nothing to step.
        if (m_frames.empty()) return Neutral();
        if (! std::isfinite(newtime) || newtime <= 0.0) return m_frames[(usize)m_curFrame];

        const usize count = m_frames.size();
        m_remainTime -= newtime;
        if (m_remainTime >= 0.0) return m_frames[(usize)m_curFrame];

        double cycle = 0.0;
        for (const auto& frame : m_frames) cycle += FrameDuration(frame);
        if (cycle <= 0.0) {
            // No timed frames: every positive tick is one step.
            m_curFrame   = (m_curFrame + 1) % (idx)count;
            m_remainTime = 0.0;
            return m_frames[(usize)m_curFrame];
        }
        // Whole cycles bring the sheet back to the same frame, so only the part of
        // the deficit beyond them is walked.
        double deficit = -m_remainTime;
        if (deficit > cycle) deficit = std::fmod(deficit, cycle);
        m_remainTime = -deficit;
        for (usize steps = 0; m_remainTime < 0.0 && steps < count; ++steps) {
            m_curFrame = (m_curFrame + 1) % (idx)count;
            m_remainTime += FrameDuration(m_frames[(usize)m_curFrame]);
        }
        return m_frames[(usize)m_curFrame];
    }
    const auto& SetFrame(double frame) {
        if (m_frames.empty()) return Neutral();
        // NaN and anything below the first frame pin frame 0; beyond the table, the last.
        double pinned = std::isnan(frame) ? 0.0 : std::floor(frame);
        pinned        = std::clamp(pinned, 0.0, (double)(m_frames.size() - 1));
        m_curFrame    = (idx)pinned;
        m_remainTime  = FrameDuration(m_frames[(usize)m_curFrame]);
        return m_frames[(usize)m_curFrame];
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
    static const SpriteFrame& Neutral() {
        static const SpriteFrame neutral {};
        return neutral;
    }
    static double FrameDuration(const SpriteFrame& frame) {
        return std::isfinite(frame.frametime) && frame.frametime > 0.0f ? frame.frametime : 0.0;
    }
    idx    m_curFrame { 0 };
    double m_remainTime { 0 };

    std::vector<SpriteFrame> m_frames;
};
} // namespace wallpaper

#include "Utils/FrameTimer.h"

using namespace wallpaper;

FrameTimer::FrameTimer() {
    // CLEANROOM U3: implement from specs/engine/e7-small-units.md
}

FrameTimer::~FrameTimer() {
    // CLEANROOM U4: implement from specs/engine/e7-small-units.md
}

void FrameTimer::SetCallback(const std::function<void()>& func) { m_callback = func; }

void FrameTimer::FrameBegin() {
    // CLEANROOM U5: implement from specs/engine/e7-small-units.md
}

void FrameTimer::FrameEnd() {
    // CLEANROOM U6: implement from specs/engine/e7-small-units.md
}

void FrameTimer::insertFrameTime(std::chrono::microseconds) {
    // CLEANROOM U7: implement from specs/engine/e7-small-units.md
}

double FrameTimer::FrameTime() const {
    // CLEANROOM U8: implement from specs/engine/e7-small-units.md
    return 0.0;
}

double FrameTimer::IdeaTime() const {
    // CLEANROOM U9: implement from specs/engine/e7-small-units.md
    return 0.0;
}

void FrameTimer::calculateFrimetime() {
    // CLEANROOM U10: implement from specs/engine/e7-small-units.md
}

void FrameTimer::SetRequiredFps(uint8_t) {
    // CLEANROOM U11: implement from specs/engine/e7-small-units.md
}

void FrameTimer::Run() {
    // CLEANROOM U12: implement from specs/engine/e7-small-units.md
}

void FrameTimer::Stop() {
    // CLEANROOM U13: implement from specs/engine/e7-small-units.md
}

// This project's own code, written from the clean-room specification
// (specs/engine/e7-small-units.md).
#include "Utils/FpsCounter.h"

#include <cstdio>

using namespace wallpaper;

namespace
{
constexpr std::chrono::seconds kReportInterval { 2 };
}

FpsCounter::FpsCounter(): m_fps(0), m_frameCount(0), m_startTime(std::chrono::steady_clock::now()) {}

// Counts one frame; every two seconds turns the count into a rate and prints it.
void FpsCounter::RegisterFrame() {
    ++m_frameCount;
    const auto now     = std::chrono::steady_clock::now();
    const auto elapsed = now - m_startTime;
    if (elapsed < kReportInterval) return;

    const double seconds = std::chrono::duration<double>(elapsed).count();
    m_fps                = static_cast<u32>(static_cast<double>(m_frameCount) / seconds + 0.5);
    std::fprintf(stderr, "INFO fps: %u\n", m_fps);
    m_frameCount = 0;
    m_startTime  = now;
}

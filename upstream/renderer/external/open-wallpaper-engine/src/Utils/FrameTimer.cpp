// This project's own code, written from the clean-room specification
// (specs/engine/e7-small-units.md).
#include "Utils/FrameTimer.h"

#include <algorithm>
#include <numeric>

using namespace wallpaper;

namespace
{
constexpr uint8_t kDefaultFps { 30 };

std::chrono::microseconds PeriodOf(uint8_t fps) {
    return std::chrono::microseconds(1'000'000 / std::max<int>(fps, 1));
}

double Seconds(std::chrono::microseconds t) { return std::chrono::duration<double>(t).count(); }
} // namespace

FrameTimer::FrameTimer(): m_required_fps(kDefaultFps) {
    m_frametimes.fill(micros::zero());
    m_frametime = micros::zero();
    m_ideatime  = PeriodOf(m_required_fps);
    m_clock     = std::chrono::steady_clock::now();
}

FrameTimer::~FrameTimer() { Stop(); }

void FrameTimer::SetCallback(const std::function<void()>& func) { m_callback = func; }

// A frame is under way from here to FrameEnd; the ticking thread does not start
// another one meanwhile.
void FrameTimer::FrameBegin() {
    m_not_end.fetch_add(1);
    m_clock = std::chrono::steady_clock::now();
}

void FrameTimer::FrameEnd() {
    insertFrameTime(std::chrono::duration_cast<micros>(std::chrono::steady_clock::now() - m_clock));
    m_not_end.fetch_sub(1);
}

void FrameTimer::insertFrameTime(std::chrono::microseconds t) {
    m_frametimes[m_frametimes_pos] = t;
    m_frametimes_pos               = (m_frametimes_pos + 1) % m_frametimes.size();
    calculateFrimetime();
}

// Seconds the last few frames took, on average.
double FrameTimer::FrameTime() const { return Seconds(m_frametime.load()); }

// Seconds one frame should take at the required rate.
double FrameTimer::IdeaTime() const { return Seconds(m_ideatime.load()); }

void FrameTimer::calculateFrimetime() {
    const micros total = std::accumulate(m_frametimes.begin(), m_frametimes.end(), micros::zero());
    m_frametime        = total / static_cast<micros::rep>(m_frametimes.size());
}

void FrameTimer::SetRequiredFps(uint8_t fps) {
    m_required_fps = fps;
    m_ideatime     = PeriodOf(fps);
    m_condition.notify_all();
}

void FrameTimer::Run() {
    if (m_running.exchange(true)) return;
    m_thread = std::thread([this] {
        auto next = std::chrono::steady_clock::now();
        std::unique_lock lock(m_cvmutex);
        while (m_running) {
            next += m_ideatime.load();
            m_condition.wait_until(lock, next, [this] { return ! m_running.load(); });
            if (! m_running) break;
            if (m_not_end.load() > 0 || ! m_callback) continue;
            lock.unlock();
            m_callback();
            lock.lock();
            // After a long frame do not fire a burst to catch up.
            next = std::max(next, std::chrono::steady_clock::now());
        }
    });
}

void FrameTimer::Stop() {
    {
        std::lock_guard lock(m_cvmutex);
        m_running = false;
    }
    m_condition.notify_all();
    if (m_thread.joinable()) m_thread.join();
}

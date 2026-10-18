#include "FrameTimer.hpp"
#include "Utils//Logging.h"

#include <algorithm>
#include <numeric>

// CLEANROOM: the stubs below leave their parameters unused until they are rewritten.
#pragma clang diagnostic ignored "-Wunused-parameter"

using namespace wallpaper;
using micros = std::chrono::microseconds;
using namespace std::chrono;

namespace
{
constexpr auto MAX_FRAME_DURATION = seconds(5);
/// Multiple of the tick interval that still counts as ordinary scheduling
/// jitter. A content-paced clock ticks at its own interval by design, so the
/// suspension threshold has to be expressed relative to that interval; three
/// intervals leaves room for a late wakeup without letting a genuine process
/// suspension feed hours into scene simulation.
constexpr i32  SUSPENSION_INTERVAL_SLACK { 3 };
constexpr u16  DEFAULT_REQUIRED_FPS { 30 };
}

FrameTimer::FrameTimer(std::function<void()> cb)
    : m_timer(std::function<void()> {}) {
    // CLEANROOM RT33
    (void)cb;
}

FrameTimer::~FrameTimer() {
    // CLEANROOM RT33
}

u16 FrameTimer::RequiredFps() const {
    // CLEANROOM RT33
    return 0;
}

double FrameTimer::FrameTime() const {
    // CLEANROOM RT33
    return 0;
}

double FrameTimer::IdeaTime() const {
    return duration_cast<duration<double>>(m_elapsed_frametime.load()).count();
}

void FrameTimer::UpdateFrametime() {
    // CLEANROOM RT33
}

void FrameTimer::AddFrametime(micros t) {
    // CLEANROOM RT33
}

void FrameTimer::SetRequiredFps(u16 value) {
    m_req_fps  = value > 0 ? value : DEFAULT_REQUIRED_FPS;
    m_ideatime = microseconds(1'000'000 / m_req_fps.load());
    // The ceiling is a hard floor on the gap between frames, separate from the
    // cadence: content pacing lengthens the cadence past the ceiling, and a
    // one-shot request has no cadence at all, so both would otherwise be
    // unbounded from below.
    m_timer.SetMinInterval(m_ideatime.load());
    // An FPS change must not discard an in-flight draw or its elapsed time.
    m_timer.SetInterval(ResolveInterval());
}

void FrameTimer::SetFrameDemand(FrameDemand demand) {
    const auto period = demand.content_period > microseconds::zero() ? demand.content_period
                                                                     : microseconds::zero();
    const auto previous_kind   = m_demand_kind.exchange(demand.kind);
    const bool period_changed  = m_content_period.exchange(period) != period;
    const bool kind_changed    = previous_kind != demand.kind;

    switch (demand.kind) {
    case FrameDemand::Kind::Idle:
        // The interval is left as it was: leaving idle has to restore a
        // cadence, and recomputing it from a stale ideal frame time at the
        // moment of the wake would make the first frame after a long sleep
        // arrive at the wrong rate.
        m_timer.SetIdle(true);
        break;
    case FrameDemand::Kind::Timed: {
        const auto deadline = demand.deadline;
        m_demand_deadline.store(deadline);
        const auto now = steady_clock::now();
        if (deadline <= now) {
            // A deadline already past is a frame that is owed, not a very long
            // wait. It has to be taken through the idle path: a one-shot
            // request is honoured immediately only while idle, so leaving the
            // clock running would defer this owed frame by a full cadence
            // interval instead of taking it now. After that frame runs, its own
            // demand decides what happens next.
            m_timer.SetIdle(true);
            m_timer.WakeOnce();
            break;
        }
        m_timer.SetIdle(true);
        m_timer.WakeAt(deadline);
        break;
    }
    case FrameDemand::Kind::Continuous:
        m_timer.SetIdle(false);
        if (period_changed || kind_changed) m_timer.SetInterval(ResolveInterval());
        break;
    }
}

void FrameTimer::RequestFrame() {
    // A stopped clock stays stopped. Waking a paused wallpaper because a
    // property changed would override the user's own decision; the frame is
    // taken when the clock is next run.
    if (! Running()) return;
    // Recorded here and cleared only by a draw. The thread timer's own latch
    // is cleared by the tick it fires, which is not the same thing: a tick
    // suppressed by an in-flight draw would otherwise consume the request
    // without drawing anything, and if that draw then leaves the scene idle
    // there is no later tick to notice.
    m_frame_requested.store(true);
    m_timer.WakeOnce();
}

bool FrameTimer::Idle() const { return m_timer.Idle(); }

std::chrono::microseconds FrameTimer::TickInterval() const { return m_tick_interval.load(); }

void FrameTimer::SetCounters(RendererCounters* counters) {
    m_counters.store(counters, std::memory_order_relaxed);
}

std::chrono::microseconds FrameTimer::SuspensionThreshold() const {
    const auto floor    = duration_cast<microseconds>(MAX_FRAME_DURATION);
    const auto relative = m_tick_interval.load() * SUSPENSION_INTERVAL_SLACK;
    return std::max(floor, relative);
}

std::chrono::microseconds FrameTimer::ResolveInterval() {
    const auto ideal  = m_ideatime.load();
    const auto period = m_content_period.load();
    auto       interval = ideal;
    if (period > ideal) {
        // Bounded on both sides: never faster than the ceiling the user and the
        // display set, and never slower than the longest gap the frame clock
        // treats as continuous playback, so a bad period cannot stall the scene.
        interval = std::min(period, duration_cast<microseconds>(MAX_FRAME_DURATION));
    }
    m_tick_interval.store(interval);
    auto* counters = m_counters.load(std::memory_order_relaxed);
    if (counters != nullptr) {
        counters->Set(OWE_RC_TICK_INTERVAL_MICROS, static_cast<u64>(interval.count()));
        counters->Set(OWE_RC_CONTENT_PERIOD_MICROS, static_cast<u64>(period.count()));
    }
    return interval;
}

void FrameTimer::FrameBegin() { FrameBegin(steady_clock::now()); }
void FrameTimer::FrameBegin(steady_clock::time_point now) {
    const auto elapsed = duration_cast<microseconds>(now - m_clock);
    // The first frame after Run has no active predecessor. A gap far longer
    // than the interval this clock is pacing at is the process having been
    // suspended, not the content waiting, and must not feed hours into scene
    // simulation. The threshold follows the interval precisely so that a scene
    // paced to its content is not mistaken for a resume on every frame.
    const bool reset = m_reset_frame_clock.exchange(false);
    m_elapsed_frametime.store(reset || elapsed > SuspensionThreshold()
                                 ? m_ideatime.load()
                                 : elapsed);
    m_clock = now;
}
void FrameTimer::FrameEnd() { FrameEnd(steady_clock::now()); }
void FrameTimer::FrameEnd(steady_clock::time_point now) {
    // CLEANROOM RT33
}

void FrameTimer::SetCallback(const std::function<void()>& cb) {
    // CLEANROOM RT33
}
void FrameTimer::Run() {
    // CLEANROOM RT33
}
void FrameTimer::Stop() {
    // CLEANROOM RT33
}
bool FrameTimer::Running() const {
    // CLEANROOM RT33
    return false;
}

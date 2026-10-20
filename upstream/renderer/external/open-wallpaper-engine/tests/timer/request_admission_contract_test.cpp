// Independently authored contract tests. The linked wpTimer implementation is
// unchanged; all rendezvous and callback wrapping belong to this translation unit.
#include "Timer/FrameTimer.hpp"
#include <gtest/gtest.h>

#include <atomic>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

namespace wallpaper {
struct TimerAdmissionTestAccess {
    using Clock = std::chrono::steady_clock;
    struct State {
        bool running, idle, request, appointment, fire_now, frame_requested;
        i32 busy;
        std::optional<Clock::time_point> owed;
        Clock::time_point due;
        std::chrono::microseconds floor;
    };

    static State Read(FrameTimer& frame) {
        auto& timer = frame.m_timer;
        std::lock_guard lock(timer.m_mutex);
        const auto owed = frame.m_owed_tick_ns.load();
        return {timer.m_running.load(), timer.m_idle, timer.m_request,
                timer.m_appointment.has_value(), timer.m_fire_now,
                frame.m_frame_requested.load(), frame.m_frame_busy_count.load(),
                owed == FrameTimer::kNoOwedTick
                    ? std::nullopt
                    : std::optional<Clock::time_point>(Clock::time_point(
                          std::chrono::duration_cast<Clock::duration>(std::chrono::nanoseconds(owed)))),
                timer.m_last_due, timer.m_min_interval};
    }

    // Installed only before Run, preserving the actual constructor's OnTick
    // closure. ThreadTimer invokes this outside its mutex, after latch consumption.
    static void Wrap(FrameTimer& frame,
                     std::function<void(const std::function<void()>&)> wrapper) {
        auto original = std::move(frame.m_timer.m_callback);
        frame.m_timer.m_callback = [original = std::move(original),
                                  wrapper = std::move(wrapper)] { wrapper(original); };
    }
    static void Begin(FrameTimer& frame, Clock::time_point when) { frame.FrameBegin(when); }
    static void End(FrameTimer& frame, Clock::time_point when) { frame.FrameEnd(when); }
};
} // namespace wallpaper

namespace {
using wallpaper::FrameTimer;
using Access = wallpaper::TimerAdmissionTestAccess;
using Clock = Access::Clock;
using namespace std::chrono_literals;

// Every attempt rendezvouses both before and after the original closure. The
// controller releases one phase at a time; timeouts are deadlock watchdogs only.
class TickBarrier {
public:
    bool Arrive(int phase) {
        std::unique_lock lock(mutex_);
        reached_ = phase;
        changed_.notify_all();
        if (!changed_.wait_for(lock, 5s, [&] { return open_ || released_ >= phase; })) {
            timed_out_ = true;
            open_ = true;
            changed_.notify_all();
        }
        return !open_;
    }
    bool Wait(int phase) {
        std::unique_lock lock(mutex_);
        return changed_.wait_for(lock, 5s, [&] { return open_ || reached_ >= phase; })
               && !open_ && reached_ == phase;
    }
    void Release(int phase) {
        std::lock_guard lock(mutex_);
        released_ = phase;
        changed_.notify_all();
    }
    void Open() {
        std::lock_guard lock(mutex_);
        open_ = true;
        changed_.notify_all();
    }
    bool TimedOut() {
        std::lock_guard lock(mutex_);
        return timed_out_;
    }
private:
    std::mutex mutex_;
    std::condition_variable changed_;
    int reached_ = 0, released_ = 0;
    bool open_ = false, timed_out_ = false;
};

struct Draw {
    Clock::time_point posted, due;
    std::chrono::microseconds floor;
    int busy;
};

class AdmissionHarness {
public:
    explicit AdmissionHarness(bool defer_first = false)
        : timer([this, defer_first] {
              const auto state = Access::Read(timer);
              const auto posted = Clock::now();
              {
                  std::lock_guard lock(draw_mutex_);
                  draws_.push_back({posted, state.due, state.floor, state.busy});
              }
              timer.FrameBegin();
              if (!defer_first || draws() != 1) timer.FrameEnd();
          }) {
        Access::Wrap(timer, [this](const std::function<void()>& original) {
            const int attempt = ++attempts_;
            if (!barrier.Arrive(2 * attempt - 1)) return;
            original();
            barrier.Arrive(2 * attempt);
        });
        timer.SetRequiredFps(60);
        timer.SetFrameDemand({FrameTimer::FrameDemand::Kind::Idle});
        timer.Run();
    }
    ~AdmissionHarness() {
        // Fatal assertions, exceptions and normal teardown all open the barriers
        // before Stop can join a worker that is waiting in our callback wrapper.
        barrier.Open();
        timer.Stop();
        // Only the first draw can defer completion. Inspect its slot only after
        // callbacks are quiescent, then balance an outstanding FrameBegin with a
        // real FrameEnd. Successful controlled completions already leave it free.
        if (Access::Read(timer).busy > 0) timer.FrameEnd();
    }
    int draws() {
        std::lock_guard lock(draw_mutex_);
        return static_cast<int>(draws_.size());
    }
    Draw draw(int index) {
        std::lock_guard lock(draw_mutex_);
        return draws_.at(index);
    }
    int attempts() const { return attempts_.load(); }
    void Batch() {
        for (int i = 0; i < 200; ++i) timer.RequestFrame();
    }
    void ExpectQuiescent(int expected_draws, int expected_attempts) {
        // Called at a held post-tick barrier, not after an absence-via-sleep.
        const auto state = Access::Read(timer);
        EXPECT_TRUE(state.running);
        EXPECT_TRUE(state.idle);
        EXPECT_FALSE(state.request);
        EXPECT_FALSE(state.appointment);
        EXPECT_FALSE(state.fire_now);
        EXPECT_FALSE(state.frame_requested);
        EXPECT_EQ(state.busy, 0);
        EXPECT_FALSE(state.owed.has_value());
        EXPECT_EQ(draws(), expected_draws);
        EXPECT_EQ(attempts(), expected_attempts);
        EXPECT_FALSE(barrier.TimedOut());
        std::lock_guard lock(draw_mutex_);
        for (std::size_t i = 0; i < draws_.size(); ++i) {
            EXPECT_EQ(draws_[i].busy, 1) << "every delivered draw owns the single slot";
            EXPECT_GE(draws_[i].posted, draws_[i].due);
            if (i > 0) {
                // Due times, not callback wall-clock slack, define the ceiling.
                // Suppressed attempts are deliberately absent from this list:
                // FireNow may follow a suppressed tick by less than one interval.
                EXPECT_GE(draws_[i].due - draws_[i - 1].due, draws_[i].floor);
            }
        }
    }

    TickBarrier barrier;
    FrameTimer timer;
private:
    std::atomic<int> attempts_ {0};
    std::mutex draw_mutex_;
    std::vector<Draw> draws_;
};

// Establish the AFTER-posting window, consume one request with a real suppressed
// OnTick, and leave that attempt held at its post-tick barrier. No private OnTick
// call or independent scheduler model is involved.
void EstablishSuppressedTick(AdmissionHarness& harness, bool delayed_begin) {
    harness.timer.RequestFrame();
    ASSERT_TRUE(harness.barrier.Wait(1));
    EXPECT_FALSE(Access::Read(harness.timer).request);
    harness.barrier.Release(1);
    ASSERT_TRUE(harness.barrier.Wait(2));
    ASSERT_EQ(harness.draws(), 1);
    EXPECT_EQ(Access::Read(harness.timer).busy, 1);
    if (delayed_begin) {
        // Positive ordering only: allow an 18 ms draw beginning after posting.
        // This wait neither counts frames nor infers that a callback was absent.
        std::this_thread::sleep_until(harness.draw(0).posted + 18ms);
    }
    harness.Batch();
    auto pending = Access::Read(harness.timer);
    EXPECT_TRUE(pending.request);
    EXPECT_TRUE(pending.frame_requested);
    harness.barrier.Release(2);
    ASSERT_TRUE(harness.barrier.Wait(3));
    auto consumed = Access::Read(harness.timer);
    EXPECT_FALSE(consumed.request);
    EXPECT_TRUE(consumed.frame_requested);
    EXPECT_EQ(consumed.busy, 1);
    harness.barrier.Release(3);
    ASSERT_TRUE(harness.barrier.Wait(4));
    auto suppressed = Access::Read(harness.timer);
    EXPECT_FALSE(suppressed.request);
    EXPECT_FALSE(suppressed.fire_now);
    EXPECT_TRUE(suppressed.frame_requested);
    EXPECT_EQ(suppressed.busy, 1);
    EXPECT_TRUE(suppressed.owed.has_value());
    EXPECT_EQ(harness.draws(), 1);
    EXPECT_EQ(harness.attempts(), 2);
}

void FinishTrailingDraw(AdmissionHarness& harness) {
    harness.barrier.Release(4);
    ASSERT_TRUE(harness.barrier.Wait(5));
    const auto consumed = Access::Read(harness.timer);
    EXPECT_FALSE(consumed.request);
    EXPECT_FALSE(consumed.fire_now);
    EXPECT_EQ(consumed.busy, 0);
    EXPECT_TRUE(consumed.frame_requested);
    harness.barrier.Release(5);
    ASSERT_TRUE(harness.barrier.Wait(6));
    harness.ExpectQuiescent(2, 3);
}

void CheckRecoveryBoundary(bool inclusive_boundary) {
    AdmissionHarness harness(true);
    ASSERT_NO_FATAL_FAILURE(EstablishSuppressedTick(harness, true));
    const auto suppressed = Access::Read(harness.timer);
    ASSERT_TRUE(suppressed.owed.has_value());
    const auto quarter = harness.timer.TickInterval() / 4;
    const auto end = *suppressed.owed + quarter + (inclusive_boundary ? 0ns : 1ns);
    const auto begin = end - 18ms;
    ASSERT_GT(begin, harness.draw(0).posted) << "render begins after posting delay";
    // These private time-point overloads test the exact recovery boundary only.
    // Never release the worker to dispatch a fake future completion, and make no
    // throughput inference from injected render timestamps.
    std::this_thread::sleep_until(end);
    ASSERT_GE(Clock::now(), end);
    Access::Begin(harness.timer, begin);
    Access::End(harness.timer, end);
    const auto recovered = Access::Read(harness.timer);
    EXPECT_EQ(recovered.busy, 0);
    EXPECT_FALSE(recovered.owed.has_value());
    EXPECT_TRUE(recovered.frame_requested);
    EXPECT_EQ(recovered.fire_now, inclusive_boundary);
    EXPECT_EQ(recovered.request, !inclusive_boundary);
    EXPECT_EQ(harness.draws(), 1);
    ASSERT_NO_FATAL_FAILURE(FinishTrailingDraw(harness));
}
} // namespace

TEST(FrameTimerTest, AnIdleBurstOfWakeOnceProducesOneCallback) {
    AdmissionHarness harness;
    harness.timer.RequestFrame();
    ASSERT_TRUE(harness.barrier.Wait(1));
    harness.barrier.Release(1);
    ASSERT_TRUE(harness.barrier.Wait(2));
    ASSERT_EQ(harness.draws(), 1); // priming draw is already complete
    harness.timer.SetFrameDemand({FrameTimer::FrameDemand::Kind::Idle});
    EXPECT_EQ(Access::Read(harness.timer).busy, 0);
    harness.Batch(); // all 200 calls return BEFORE Loop can consume the latch
    const auto pending = Access::Read(harness.timer);
    EXPECT_TRUE(pending.idle);
    EXPECT_TRUE(pending.request);
    EXPECT_TRUE(pending.frame_requested);
    harness.barrier.Release(2);
    ASSERT_TRUE(harness.barrier.Wait(3));
    EXPECT_FALSE(Access::Read(harness.timer).request);
    harness.barrier.Release(3);
    ASSERT_TRUE(harness.barrier.Wait(4));
    harness.ExpectQuiescent(2, 2); // one prime plus exactly one batch draw
}

TEST(RequestAdmissionContractTest, ConsumedLatchBeforeOnTickLeavesOnePendingDraw) {
    AdmissionHarness harness;
    harness.timer.RequestFrame();
    ASSERT_TRUE(harness.barrier.Wait(1)); // latch consumed; OnTick has not run
    EXPECT_FALSE(Access::Read(harness.timer).request);
    EXPECT_EQ(harness.draws(), 0);
    harness.Batch();
    EXPECT_TRUE(Access::Read(harness.timer).request);
    harness.barrier.Release(1);
    ASSERT_TRUE(harness.barrier.Wait(2)); // selected draw completes synchronously
    EXPECT_EQ(harness.draws(), 1);
    const auto selected = Access::Read(harness.timer);
    EXPECT_EQ(selected.busy, 0);
    EXPECT_TRUE(selected.request);
    EXPECT_FALSE(selected.frame_requested); // selected admission cleared it
    harness.barrier.Release(2);
    ASSERT_TRUE(harness.barrier.Wait(3));
    EXPECT_FALSE(Access::Read(harness.timer).request);
    harness.barrier.Release(3);
    ASSERT_TRUE(harness.barrier.Wait(4));
    harness.ExpectQuiescent(2, 2);
}

TEST(RequestAdmissionContractTest, RequestsAfterPostingSurviveASuppressedTick) {
    AdmissionHarness harness(true);
    ASSERT_NO_FATAL_FAILURE(EstablishSuppressedTick(harness, false));
    const auto suppressed = Access::Read(harness.timer);
    ASSERT_TRUE(suppressed.owed.has_value());
    const auto outside = *suppressed.owed + harness.timer.TickInterval() / 4 + 1us;
    std::this_thread::sleep_until(outside);
    ASSERT_GT(Clock::now() - *suppressed.owed, harness.timer.TickInterval() / 4);
    harness.timer.FrameEnd(); // actual completion time, outside recovery window
    const auto rearmed = Access::Read(harness.timer);
    EXPECT_EQ(rearmed.busy, 0);
    EXPECT_FALSE(rearmed.owed.has_value());
    EXPECT_TRUE(rearmed.frame_requested);
    EXPECT_TRUE(rearmed.request);
    EXPECT_FALSE(rearmed.fire_now);
    ASSERT_NO_FATAL_FAILURE(FinishTrailingDraw(harness));
}

TEST(RequestAdmissionContractTest, RecoveryAtExactlyOneQuarterIntervalFiresNow) {
    CheckRecoveryBoundary(true);
}

TEST(RequestAdmissionContractTest, RecoveryOneNanosecondBeyondQuarterRearmsRequest) {
    CheckRecoveryBoundary(false);
}

TEST(RequestAdmissionContractTest, SuppressedTickUsesObservationTime) {
    AdmissionHarness harness(true);
    harness.timer.RequestFrame();
    ASSERT_TRUE(harness.barrier.Wait(1));
    harness.barrier.Release(1);
    ASSERT_TRUE(harness.barrier.Wait(2));
    ASSERT_EQ(harness.draws(), 1);
    ASSERT_EQ(Access::Read(harness.timer).busy, 1);

    harness.Batch();
    harness.barrier.Release(2);
    ASSERT_TRUE(harness.barrier.Wait(3));
    const auto consumed = Access::Read(harness.timer);
    ASSERT_FALSE(consumed.request);
    ASSERT_TRUE(consumed.frame_requested);
    ASSERT_EQ(consumed.busy, 1);
    ASSERT_FALSE(consumed.owed.has_value());

    // Hold the actual second callback before OnTick until its due time is past.
    // This is positive ordering, not a bound on OS callback delivery latency.
    std::this_thread::sleep_until(consumed.due + 1ms);
    const auto before_observation = Clock::now();
    ASSERT_GT(before_observation, consumed.due);
    harness.barrier.Release(3);
    ASSERT_TRUE(harness.barrier.Wait(4));
    const auto after_observation = Clock::now();
    const auto suppressed = Access::Read(harness.timer);
    ASSERT_TRUE(suppressed.owed.has_value());
    EXPECT_GE(*suppressed.owed, before_observation);
    EXPECT_LE(*suppressed.owed, after_observation);
    EXPECT_GT(*suppressed.owed, consumed.due);
    EXPECT_EQ(suppressed.busy, 1);
    EXPECT_TRUE(suppressed.frame_requested);
    EXPECT_FALSE(suppressed.request);
    EXPECT_FALSE(suppressed.fire_now);
    EXPECT_EQ(harness.draws(), 1);
    EXPECT_EQ(harness.attempts(), 2);

    // Complete real work while the suppressed callback remains at its post-tick
    // barrier. The existing boundary cases, not this case, select recovery timing.
    harness.timer.FrameEnd();
    ASSERT_NO_FATAL_FAILURE(FinishTrailingDraw(harness));
}

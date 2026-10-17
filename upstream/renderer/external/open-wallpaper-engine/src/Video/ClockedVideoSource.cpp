#include "Video/ClockedVideoSource.hpp"

#include "Platform/Apple/VideoFrameInterop.hpp"
#include "Utils/Logging.h"
#include "Video/VideoSeekPolicy.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <exception>
#include <limits>
#include <utility>

namespace wallpaper::video
{
namespace
{

constexpr auto kPrimeTimeout = std::chrono::seconds(2);
constexpr auto kDecodePoll = std::chrono::milliseconds(2);

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

double WrapSeconds(double seconds, double duration_seconds)
{
    if (!(duration_seconds > 0.0) || !std::isfinite(seconds)) return 0.0;
    double wrapped = std::fmod(seconds, duration_seconds);
    if (wrapped < 0.0) wrapped += duration_seconds;
    if (wrapped >= duration_seconds) wrapped = 0.0;
    return wrapped;
}

/// Identity of a running decoder instance. Monotonic and never reused, so a
/// report can de-duplicate one source's work across several consumers without
/// ever merging two decoders that happen to read the same file.
uint64_t NextVideoSourceInstanceId()
{
    static std::atomic<uint64_t> next { 1 };
    return next.fetch_add(1, std::memory_order_relaxed);
}

} // namespace

ClockedVideoSource::ClockedVideoSource(std::unique_ptr<VideoFrameBackend> backend,
                                       std::string                        debug_label,
                                       std::string                        initial_error)
    : m_backend(std::move(backend)),
      m_debug_label(std::move(debug_label)),
      m_initial_error(std::move(initial_error)),
      m_instance_id(NextVideoSourceInstanceId())
{
    if (m_backend == nullptr && m_initial_error.empty()) m_initial_error = "video source has no decoder";
}

ClockedVideoSource::~ClockedVideoSource()
{
    stop();
    clearFrames();
    if (m_backend != nullptr) m_backend->close();
}

bool ClockedVideoSource::prime(std::string* error)
{
    // Every consumer waits for the same complete attempt, including its
    // failure. Decoder handles and the worker thread have one initializer.
    std::call_once(m_prime_once, [this] {
        try {
            m_prime_succeeded = primeOnce(&m_prime_error);
        } catch (const std::exception& exception) {
            m_prime_error = std::string("failed to initialize video: ") + exception.what();
        }
        if (! m_prime_succeeded) {
            stop();
            clearFrames();
            if (m_backend != nullptr) m_backend->close();
        }
    });
    if (m_prime_succeeded) return true;
    return SetError(error, m_prime_error);
}

bool ClockedVideoSource::primeOnce(std::string* error)
{
    std::unique_lock lock(m_mutex);
    if (m_primed) return true;
    if (!m_initial_error.empty()) return SetError(error, m_initial_error);
    lock.unlock();

    std::string local_error;
    if (!m_backend->open(&local_error)) {
        return SetError(error, std::move(local_error));
    }
    {
        const auto info = m_backend->streamInfo();
        m_duration_seconds = info.duration_seconds;
        m_frame_duration_seconds = info.frame_duration_seconds;
        // The declared rates seed the estimator as an upper bound on the
        // period; decoded timestamps are what actually unlock pacing.
        m_pacing.Reset(info.shortest_declared_period_seconds);
    }

    {
        std::lock_guard state_lock(m_mutex);
        m_scene_absolute_seconds = 0.0;
        m_clock_base_seconds = 0.0;
        m_clock_initialized = true;
        m_running = true;
        m_stop_requested = false;
    }

    m_decode_thread = std::thread([this]() { decodeLoop(); });

    lock.lock();
    const auto ready = m_condition.wait_for(
        lock,
        kPrimeTimeout,
        [this]() {
            return m_display_frame_ready || !m_last_error.empty();
        });
    if (!ready) {
        lock.unlock();
        stop();
        return SetError(error, "timed out waiting for the first video frame");
    }
    if (!m_last_error.empty()) {
        const std::string failure = m_last_error;
        lock.unlock();
        stop();
        return SetError(error, failure);
    }

    m_primed = true;
    return true;
}

bool ClockedVideoSource::syncPlayback(const VideoPlaybackState& state, std::string* error)
{
    if (state.rate < 0.0f) return SetError(error, "negative video playback rates are not supported");

    std::lock_guard lock(m_mutex);
    if (!m_last_error.empty()) return SetError(error, m_last_error);

    const auto now = std::chrono::steady_clock::now();
    const double requested_absolute_seconds = std::max(0.0, state.scene_elapsed_seconds);
    m_scene_absolute_seconds = requested_absolute_seconds;
    m_clock_base_seconds = WrapSeconds(requested_absolute_seconds, m_duration_seconds);
    m_clock_base_time = now;
    m_clock_initialized = true;
    m_playback_state = state;
    m_playback_state.rate = std::max(state.rate, 0.0f);
    const double discontinuity_threshold = std::max(0.5, m_frame_duration_seconds * 8.0);
    if (m_display_frame_ready &&
        requested_absolute_seconds + discontinuity_threshold < m_display_frame.absolute_seconds) {
        clearDisplayFrameLocked();
        requestSeekLocked(requested_absolute_seconds);
        // A seek, or a display slot that just went empty, is the only reason
        // the decode thread has new work. An ordinary clock update does not.
        m_condition.notify_all();
    }
    return true;
}

bool ClockedVideoSource::refreshFrame(std::string* error)
{
    std::unique_lock lock(m_mutex);
    if (!m_last_error.empty() && !m_display_frame_ready) {
        return SetError(error, m_last_error);
    }

    const double desired_absolute_seconds = currentDesiredAbsoluteLocked();
    const double backward_threshold = std::max(0.05, m_frame_duration_seconds * 2.0);
    if (m_display_frame_ready &&
        desired_absolute_seconds + backward_threshold < m_display_frame.absolute_seconds) {
        clearDisplayFrameLocked();
        requestSeekLocked(desired_absolute_seconds);
    }

    const double forward_resync_threshold = ForwardResyncSeconds(
        m_frame_duration_seconds, static_cast<double>(kDecodedFrameQueueCapacity),
        m_seek_landing_lag_seconds);
    if (!seekInFlightCoversLocked(desired_absolute_seconds, backward_threshold,
                                  forward_resync_threshold) &&
        (!m_display_frame_ready ||
         desired_absolute_seconds > latestBufferedAbsoluteLocked() + forward_resync_threshold)) {
        requestSeekLocked(desired_absolute_seconds);
    }
    // A seek requested above, or a display frame just cleared, is work the
    // decode thread cannot see until it is woken. Promoting a queued frame
    // is the other one: it freed a slot the thread may be waiting on.
    if (m_seek_requested) m_condition.notify_all();

    bool promoted = false;
    while (!m_pending_frames.empty() &&
           (!m_display_frame_ready ||
            m_pending_frames.front().absolute_seconds <=
                desired_absolute_seconds + presentationSlackSeconds())) {
        promoted = promoteNextFrameLocked() || promoted;
    }
    if (m_display_frame_ready) {
        // Promoting freed a queue slot. The display frame staying put did not.
        if (promoted || m_seek_requested) m_condition.notify_all();
        return true;
    }

    const auto deadline = std::chrono::steady_clock::now() + kPrimeTimeout;
    while (true) {
        while (!m_pending_frames.empty() &&
               (!m_display_frame_ready ||
                m_pending_frames.front().absolute_seconds <=
                    desired_absolute_seconds + presentationSlackSeconds())) {
            promoteNextFrameLocked();
        }

        if (m_display_frame_ready ||
            displayFrameCoversDesiredLocked(desired_absolute_seconds)) {
            return true;
        }

        if (!m_last_error.empty() && !m_display_frame_ready) {
            return SetError(error, m_last_error);
        }

        if (std::chrono::steady_clock::now() >= deadline) {
            if (m_display_frame_ready) {
                return true;
            }
            return SetError(error, "video frame is not ready");
        }

        // Still waiting on a frame this thread does not have. Wake the
        // decoder only if a seek or an empty display slot is outstanding;
        // the poll below is what notices a frame arriving either way.
        if (m_seek_requested || !m_display_frame_ready) m_condition.notify_all();
        m_condition.wait_for(lock, kDecodePoll, [this]() {
            return m_stop_requested || !m_last_error.empty() || !m_pending_frames.empty();
        });
    }
}

VideoTextureFrame ClockedVideoSource::currentFrame() const
{
    std::lock_guard lock(m_mutex);
    if (!m_display_frame_ready) return {};
    return m_display_frame.frame;
}

bool ClockedVideoSource::retainCurrentFrame(VideoTextureFrame* out) const
{
    if (out == nullptr) return false;
    // Retaining inside the lock is the whole point: promotion releases the
    // previous display frame under this same lock, so a reader that has the
    // lock cannot have its frame freed underneath it.
    std::lock_guard lock(m_mutex);
    if (!m_display_frame_ready) return false;
    RetainAppleVideoFrame(m_display_frame.frame, out);
    return true;
}

double ClockedVideoSource::durationSeconds() const
{
    std::lock_guard lock(m_mutex);
    return m_duration_seconds;
}

double ClockedVideoSource::playbackSeconds() const
{
    std::lock_guard lock(m_mutex);
    return currentDesiredSecondsLocked();
}

uint64_t ClockedVideoSource::loopCount() const
{
    std::lock_guard lock(m_mutex);
    return m_loop_count;
}

double ClockedVideoSource::frameDurationSeconds() const
{
    std::lock_guard lock(m_mutex);
    // Zero until enough real presentation timestamps have been seen, which
    // the frame clock reads as "unknown" and answers with the fixed
    // cadence. Declared rates alone never unlock pacing.
    return m_primed ? m_pacing.PeriodSeconds() : 0.0;
}

VideoSourceStats ClockedVideoSource::sourceStats() const
{
    std::lock_guard lock(m_mutex);
    return VideoSourceStats {
        .instance_id = m_instance_id,
        .decoded_frames = m_decoded_frame_count,
        .seek_requests = m_seek_request_count,
        .observed_period_seconds = m_pacing.ObservedPeriodSeconds(),
        .observed_samples = m_pacing.SampleCount(),
    };
}

void ClockedVideoSource::stop()
{
    // Published before the lock so the decode thread's inner loops and any
    // blocking read in the backend observe it without waiting on us.
    if (m_backend != nullptr) m_backend->cancel();
    {
        std::lock_guard lock(m_mutex);
        if (!m_running && !m_decode_thread.joinable()) return;
        m_stop_requested = true;
        m_running = false;
        m_condition.notify_all();
    }
    if (m_decode_thread.joinable()) m_decode_thread.join();
}

void ClockedVideoSource::releaseFrameSlot(DecodedFrameSlot* slot)
{
    if (slot == nullptr) return;
    ReleaseAppleVideoFrame(&slot->frame);
    slot->ready = false;
    slot->pts_seconds = 0.0;
    slot->absolute_seconds = 0.0;
    slot->loop_index = 0;
    slot->frame = {};
}

void ClockedVideoSource::clearPendingFramesLocked()
{
    for (auto& slot : m_pending_frames) {
        releaseFrameSlot(&slot);
    }
    m_pending_frames.clear();
}

void ClockedVideoSource::clearDisplayFrameLocked()
{
    if (!m_display_frame_ready) return;
    releaseFrameSlot(&m_display_frame);
    m_display_frame_ready = false;
}

void ClockedVideoSource::clearFrames()
{
    std::lock_guard lock(m_mutex);
    clearPendingFramesLocked();
    clearDisplayFrameLocked();
}

double ClockedVideoSource::currentDesiredAbsoluteLocked() const
{
    return std::max(0.0, m_scene_absolute_seconds);
}

double ClockedVideoSource::currentDesiredSecondsLocked() const
{
    if (!m_clock_initialized) return 0.0;
    return WrapSeconds(currentDesiredAbsoluteLocked(), m_duration_seconds);
}

double ClockedVideoSource::presentationSlackSeconds() const
{
    return std::min(0.001, m_frame_duration_seconds * 0.1);
}

double ClockedVideoSource::latestBufferedAbsoluteLocked() const
{
    if (!m_pending_frames.empty()) return m_pending_frames.back().absolute_seconds;
    if (m_display_frame_ready) return m_display_frame.absolute_seconds;
    return -std::numeric_limits<double>::infinity();
}

void ClockedVideoSource::requestSeekLocked(double absolute_seconds)
{
    m_requested_seek_absolute_seconds = std::max(0.0, absolute_seconds);
    m_seek_requested = true;
    m_seek_awaiting_frame = true;
    m_seek_requested_at = std::chrono::steady_clock::now();
    ++m_seek_ticket;
    ++m_seek_request_count;
    clearPendingFramesLocked();
}

double ClockedVideoSource::secondsSinceSeekRequestedLocked() const
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - m_seek_requested_at).count();
}

/// Whether a seek that has been asked for and has not yet delivered a frame
/// is still fetching what the clock wants (`SeekOnItsWayCoversClock`).
///
/// Asked for on every call of a draw, a seek that takes longer than the time
/// between two draws, as one of a large clip does, would never land, and the
/// display would stay on the frame it had.
bool ClockedVideoSource::seekInFlightCoversLocked(double desired_absolute_seconds,
                                                  double backward_slack,
                                                  double forward_slack) const
{
    if (!m_seek_awaiting_frame) return false;
    return SeekOnItsWayCoversClock(m_requested_seek_absolute_seconds, desired_absolute_seconds,
                                   secondsSinceSeekRequestedLocked(), m_playback_state.rate,
                                   backward_slack, forward_slack);
}

bool ClockedVideoSource::displayFrameCoversDesiredLocked(double desired_absolute_seconds) const
{
    if (!m_display_frame_ready) return false;
    if (desired_absolute_seconds + presentationSlackSeconds() < m_display_frame.absolute_seconds) {
        return false;
    }

    double display_end_absolute_seconds =
        m_display_frame.absolute_seconds + m_frame_duration_seconds;
    if (!m_pending_frames.empty() &&
        m_pending_frames.front().absolute_seconds > m_display_frame.absolute_seconds) {
        display_end_absolute_seconds = m_pending_frames.front().absolute_seconds;
    }

    return desired_absolute_seconds <
        display_end_absolute_seconds + presentationSlackSeconds();
}

bool ClockedVideoSource::promoteNextFrameLocked()
{
    if (m_pending_frames.empty()) return false;

    auto next_frame = std::move(m_pending_frames.front());
    m_pending_frames.pop_front();
    if (m_display_frame_ready) {
        if (next_frame.loop_index > m_display_frame.loop_index) {
            m_loop_count += next_frame.loop_index - m_display_frame.loop_index;
        }
        releaseFrameSlot(&m_display_frame);
    }

    m_display_frame = std::move(next_frame);
    m_display_frame_ready = true;
    return true;
}

bool ClockedVideoSource::seekBackendToAbsolute(double absolute_seconds, std::string* error)
{
    const double clamped_absolute_seconds = std::max(0.0, absolute_seconds);
    const double wrapped_seconds = WrapSeconds(clamped_absolute_seconds, m_duration_seconds);
    return m_backend->seek(
        wrapped_seconds,
        m_duration_seconds > 0.0
            ? static_cast<uint64_t>(std::floor(clamped_absolute_seconds / m_duration_seconds))
            : 0,
        error);
}

ClockedVideoSource::DecodeOutcome ClockedVideoSource::decodeNextFrame(double minimum_absolute_seconds,
                                                                       DecodedFrameSlot* out,
                                                                       std::string* error)
{
    if (out == nullptr) {
        SetError(error, "decoded frame output must not be null");
        return DecodeOutcome::Failed;
    }
    bool enforce_minimum =
        std::isfinite(minimum_absolute_seconds) && minimum_absolute_seconds > 0.0;
    const uint64_t loop_index_at_entry = m_backend->loopIndex();

    while (true) {
        VideoFrameBackend::DecodedPosition position;
        switch (m_backend->decodeNext(WrapSeconds(minimum_absolute_seconds, m_duration_seconds),
                                      &position, error)) {
        case VideoFrameBackend::Decode::Cancelled:
            return DecodeOutcome::Cancelled;
        case VideoFrameBackend::Decode::Failed:
            return DecodeOutcome::Failed;
        case VideoFrameBackend::Decode::Frame:
            break;
        }

        const uint64_t loop_index = position.loop_index;
        const double frame_pts_seconds = position.pts_seconds;
        const double frame_absolute_seconds =
            (m_duration_seconds > 0.0
                 ? static_cast<double>(loop_index) * m_duration_seconds
                 : 0.0) + frame_pts_seconds;
        if (enforce_minimum &&
            frame_absolute_seconds + m_frame_duration_seconds < minimum_absolute_seconds) {
            m_backend->discardFrame();
            // A requested position past everything this stream contains
            // must not filter frames forever: once a full loop has been
            // decoded without a match, take the next frame.
            if (loop_index > loop_index_at_entry) enforce_minimum = false;
            continue;
        }

        VideoTextureFrame frame {};
        if (!m_backend->takeFrame(&frame, error)) {
            return DecodeOutcome::Failed;
        }
        frame.pts_seconds = frame_absolute_seconds;
        out->frame = frame;
        out->pts_seconds = frame_absolute_seconds;
        out->absolute_seconds = frame_absolute_seconds;
        out->loop_index = loop_index;
        out->ready = true;
        return DecodeOutcome::Frame;
    }
}

void ClockedVideoSource::queueDecodedFrame(DecodedFrameSlot frame_slot, uint64_t seek_ticket)
{
    std::lock_guard lock(m_mutex);
    if (m_stop_requested || seek_ticket != m_seek_ticket) {
        releaseFrameSlot(&frame_slot);
        return;
    }

    if (m_seek_awaiting_frame) {
        m_seek_awaiting_frame = false;
        m_seek_landing_lag_seconds =
            ClockRunOnSeconds(secondsSinceSeekRequestedLocked(), m_playback_state.rate);
    }
    frame_slot.frame.generation = m_next_generation++;
    ++m_decoded_frame_count;
    // Evidence for pacing comes from here, where a real decoded timestamp
    // exists. Deltas across a loop seam or a seek describe the seam, not
    // the content, so the run identity travels with the sample.
    m_pacing.Observe(frame_slot.absolute_seconds, frame_slot.loop_index, seek_ticket);
    m_pending_frames.push_back(std::move(frame_slot));
    if (!m_display_frame_ready) {
        promoteNextFrameLocked();
    }
    m_condition.notify_all();
}

void ClockedVideoSource::fail(std::string error)
{
    // A decode thread that dies after the first frame is otherwise
    // invisible: `refreshFrame` keeps answering with the frame already on
    // screen, so the wallpaper freezes without a word anywhere. The
    // message is recorded once, by the first failure to reach here.
    std::string reported;
    {
        std::lock_guard lock(m_mutex);
        if (m_last_error.empty()) {
            m_last_error = std::move(error);
            reported     = m_last_error;
        }
        m_running = false;
        m_condition.notify_all();
    }
    if (reported.empty()) return;
    LOG_ERROR("video decoding stopped for \"%s\": %s",
              m_debug_label.c_str(),
              reported.c_str());
}

void ClockedVideoSource::decodeLoop()
{
    while (true) {
        double minimum_absolute_seconds = -std::numeric_limits<double>::infinity();
        bool   perform_seek = false;
        double seek_absolute_seconds = 0.0;
        uint64_t decode_seek_ticket = 0;

        {
            std::unique_lock lock(m_mutex);
            m_condition.wait(lock, [this]() {
                return m_stop_requested ||
                    m_seek_requested ||
                    m_pending_frames.size() < kDecodedFrameQueueCapacity ||
                    !m_display_frame_ready;
            });
            if (m_stop_requested) break;
            decode_seek_ticket = m_seek_ticket;
            if (m_seek_requested) {
                perform_seek = true;
                seek_absolute_seconds = m_requested_seek_absolute_seconds;
                m_seek_requested = false;
                minimum_absolute_seconds = seek_absolute_seconds;
            }
        }

        if (perform_seek) {
            std::string error;
            if (!seekBackendToAbsolute(seek_absolute_seconds, &error)) {
                fail(std::move(error));
                break;
            }
        }

        DecodedFrameSlot frame_slot {};
        std::string      error;
        const DecodeOutcome outcome =
            decodeNextFrame(minimum_absolute_seconds, &frame_slot, &error);
        if (outcome == DecodeOutcome::Cancelled) break;
        if (outcome == DecodeOutcome::Failed) {
            fail(std::move(error));
            break;
        }
        queueDecodedFrame(std::move(frame_slot), decode_seek_ticket);
    }
}

} // namespace wallpaper::video

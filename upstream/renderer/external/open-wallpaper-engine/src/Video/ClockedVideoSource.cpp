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

bool SetError(std::string* error, std::string message)
{
    (void)error;
    (void)message;
    return false; // CLEANROOM MV65
}

double WrapSeconds(double seconds, double duration_seconds)
{
    (void)seconds;
    (void)duration_seconds;
    return 0.0; // CLEANROOM MV66
}

/// Identity of a running decoder instance. Monotonic and never reused, so a
/// report can de-duplicate one source's work across several consumers without
/// ever merging two decoders that happen to read the same file.
uint64_t NextVideoSourceInstanceId()
{
    static std::atomic<uint64_t> next { 1 };
    return next.fetch_add(1, std::memory_order_relaxed);
}

std::atomic<int> g_open_decoders { 0 };

} // namespace

int OpenVideoDecoderCount() { return g_open_decoders.load(std::memory_order_relaxed); }

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
    if (m_counted_open) g_open_decoders.fetch_sub(1, std::memory_order_relaxed);
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
    (void)error;
    return false; // CLEANROOM MV67
}

bool ClockedVideoSource::syncPlayback(const VideoPlaybackState& state, std::string* error)
{
    (void)state;
    (void)error;
    return true; // CLEANROOM MV68
}

bool ClockedVideoSource::refreshFrame(std::string* error)
{
    (void)error;
    return false; // CLEANROOM MV69
}

VideoTextureFrame ClockedVideoSource::currentFrame() const
{
    return {}; // CLEANROOM MV70
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
    return 0.0; // CLEANROOM MV71
}

double ClockedVideoSource::playbackSeconds() const
{
    return 0.0; // CLEANROOM MV72
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
    // CLEANROOM MV73
    if (m_decode_thread.joinable()) m_decode_thread.join();
}

void ClockedVideoSource::releaseFrameSlot(DecodedFrameSlot* slot)
{
    (void)slot; // CLEANROOM MV74
}

void ClockedVideoSource::clearPendingFramesLocked()
{
    // CLEANROOM MV75
}

void ClockedVideoSource::clearDisplayFrameLocked()
{
    // CLEANROOM MV76
}

void ClockedVideoSource::clearFrames()
{
    // CLEANROOM MV77
}

double ClockedVideoSource::currentDesiredAbsoluteLocked() const
{
    return std::max(0.0, m_scene_absolute_seconds);
}

double ClockedVideoSource::currentDesiredSecondsLocked() const
{
    return 0.0; // CLEANROOM MV78
}

double ClockedVideoSource::presentationSlackSeconds() const
{
    return std::min(0.001, m_frame_duration_seconds * 0.1);
}

double ClockedVideoSource::latestBufferedAbsoluteLocked() const
{
    return 0.0; // CLEANROOM MV79
}

void ClockedVideoSource::requestSeekLocked(double absolute_seconds)
{
    (void)absolute_seconds; // CLEANROOM MV80
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
    (void)desired_absolute_seconds;
    return false; // CLEANROOM MV81
}

bool ClockedVideoSource::promoteNextFrameLocked()
{
    return false; // CLEANROOM MV82
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
    (void)minimum_absolute_seconds;
    (void)out;
    (void)error;
    return DecodeOutcome::Cancelled; // CLEANROOM MV83
}

void ClockedVideoSource::queueDecodedFrame(DecodedFrameSlot frame_slot, uint64_t seek_ticket)
{
    (void)frame_slot;
    (void)seek_ticket; // CLEANROOM MV84
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
    // CLEANROOM MV85
}

} // namespace wallpaper::video

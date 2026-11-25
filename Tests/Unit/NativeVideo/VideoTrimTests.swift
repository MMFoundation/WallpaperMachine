import AVFoundation
import CoreMedia
import XCTest
import WallpaperMedia
import os

@testable import WallpaperMachine

/// Records samples fed by `WebMFeeder` without touching a window or renderer.
private final class TrimRecordingSink: WebMSampleSink {
    var room: Int
    private(set) var buffers: [CMSampleBuffer] = []

    init(room: Int) { self.room = room }
    var hasRoom: Bool { room > 0 }

    func accept(_ buffer: CMSampleBuffer) {
        buffers.append(buffer)
        room -= 1
    }

    var times: [Double] {
        buffers.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
    }

    var visibleBuffers: [CMSampleBuffer] {
        buffers.filter { buffer in
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
            return (attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool) != true
        }
    }

    var visibleTimes: [Double] {
        visibleBuffers.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
    }
}

@MainActor
final class VideoTrimTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-trim-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func openWebM(_ data: Data) throws -> WebMFile {
        switch WebMOpening.open(data: data) {
        case .success(let file): return file
        case .failure(let failure): throw failure
        }
    }

    // MARK: - VideoTrimRange validation & clamping

    func testTrimRangeValidationRejectsInvalidInputs() {
        XCTAssertThrowsError(try VideoTrimRange(startSeconds: -0.1, endSeconds: 2.0))
        XCTAssertThrowsError(try VideoTrimRange(startSeconds: 2.0, endSeconds: 2.0))
        XCTAssertThrowsError(try VideoTrimRange(startSeconds: 3.0, endSeconds: 1.0))
        XCTAssertThrowsError(try VideoTrimRange(startSeconds: 0.0, endSeconds: 0.49))
        XCTAssertThrowsError(try VideoTrimRange(startSeconds: .nan, endSeconds: 2.0))
        XCTAssertThrowsError(try VideoTrimRange(startSeconds: 0.0, endSeconds: .infinity))
        XCTAssertThrowsError(try VideoTrimRange(startSeconds: -.infinity, endSeconds: 2.0))
    }

    func testTrimRangeAcceptsExactMinimumDurationIncludingDecimalRounding() throws {
        let a = try VideoTrimRange(startSeconds: 0.0, endSeconds: 0.5)
        XCTAssertEqual(a.duration, 0.5, accuracy: 1e-9)

        // IEEE-754: 1.2 - 0.7 == 0.4999999999999999, which must still be accepted as 0.5s.
        let b = try VideoTrimRange(startSeconds: 0.7, endSeconds: 1.2)
        XCTAssertEqual(b.duration, 0.5, accuracy: 1e-9)

        let c = try VideoTrimRange(startSeconds: 10.1, endSeconds: 10.6)
        XCTAssertEqual(c.duration, 0.5, accuracy: 1e-9)
    }

    func testTrimRangeDecoderRejectsCorruptPayload() {
        let badJSON = Data(#"{"startSeconds":5.0,"endSeconds":5.2}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(VideoTrimRange.self, from: badJSON))

        let negativeJSON = Data(#"{"startSeconds":-1.0,"endSeconds":2.0}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(VideoTrimRange.self, from: negativeJSON))
    }

    func testTrimRangeClampsCleanlyAgainstAssetDuration() throws {
        let range = try VideoTrimRange(startSeconds: 2.0, endSeconds: 10.0)

        let within = try XCTUnwrap(range.clamped(toAssetDuration: 15.0))
        XCTAssertEqual(within.startSeconds, 2.0, accuracy: 1e-9)
        XCTAssertEqual(within.endSeconds, 10.0, accuracy: 1e-9)

        let shortened = try XCTUnwrap(range.clamped(toAssetDuration: 5.0))
        XCTAssertEqual(shortened.startSeconds, 2.0, accuracy: 1e-9)
        XCTAssertEqual(shortened.endSeconds, 5.0, accuracy: 1e-9)

        // Remaining span is 0.4s (< 0.5s minimum): falls back cleanly to nil.
        XCTAssertNil(range.clamped(toAssetDuration: 2.4))
        XCTAssertNil(range.clamped(toAssetDuration: 1.0))
        XCTAssertNil(range.clamped(toAssetDuration: 0.3))
        XCTAssertNil(range.clamped(toAssetDuration: .nan))
    }

    func testCMTimeRangeClampingHonorsNonZeroTrackStart() throws {
        let trackStart = CMTime(seconds: 1.5, preferredTimescale: 600)
        let trackDuration = CMTime(seconds: 6.0, preferredTimescale: 600)
        let trackRange = CMTimeRange(start: trackStart, duration: trackDuration)

        let trim = try VideoTrimRange(startSeconds: 1.0, endSeconds: 4.5)
        let effective = VideoTrimRange.effectiveLoopRange(trackRange: trackRange, trim: trim)
        XCTAssertTrue(effective.isValid)
        XCTAssertEqual(effective.start.seconds, 2.5, accuracy: 0.002)
        XCTAssertEqual(effective.duration.seconds, 3.5, accuracy: 0.002)

        // Trim beyond track end falls back to full track range when remaining < 0.5s.
        let tooLate = try VideoTrimRange(startSeconds: 5.8, endSeconds: 8.0)
        let fallback = VideoTrimRange.effectiveLoopRange(trackRange: trackRange, trim: tooLate)
        XCTAssertEqual(fallback.start.seconds, 1.5, accuracy: 0.002)
        XCTAssertEqual(fallback.duration.seconds, 6.0, accuracy: 0.002)
    }

    func testTimestampFormattingAndParsing() {
        XCTAssertEqual(VideoTrimRange.formatTimestamp(0), "00:00.0")
        XCTAssertEqual(VideoTrimRange.formatTimestamp(5.5), "00:05.5")
        XCTAssertEqual(VideoTrimRange.formatTimestamp(62.34), "01:02.3")
        XCTAssertEqual(VideoTrimRange.formatTimestamp(754.9), "12:34.9")
        XCTAssertEqual(VideoTrimRange.formatTimestamp(-3), "00:00.0")
        XCTAssertEqual(VideoTrimRange.formatTimestamp(.nan), "00:00.0")

        XCTAssertEqual(VideoTrimRange.parseTimestamp("00:05.5") ?? -1, 5.5, accuracy: 1e-6)
        XCTAssertEqual(VideoTrimRange.parseTimestamp("01:02.3") ?? -1, 62.3, accuracy: 1e-6)
        XCTAssertEqual(VideoTrimRange.parseTimestamp("02:10") ?? -1, 130.0, accuracy: 1e-6)
        XCTAssertEqual(VideoTrimRange.parseTimestamp("12.4") ?? -1, 12.4, accuracy: 1e-6)
        XCTAssertNil(VideoTrimRange.parseTimestamp(""))
        XCTAssertNil(VideoTrimRange.parseTimestamp("01:60.0"))
        XCTAssertNil(VideoTrimRange.parseTimestamp("-1:00.0"))
        XCTAssertNil(VideoTrimRange.parseTimestamp("abc"))
    }

    // MARK: - AVFoundation AVPlayerLooper CMTimeRange

    func testNativeVideoLoopRangeAppliesAndClampsTrimOnSyntheticAsset() async throws {
        var request = SyntheticVideoFixture.Request.constantRate(
            name: "trim-av", numerator: 30, denominator: 1, frames: 60) // 2.0s video
        request.withAudio = true
        request.audioSeconds = 2.6 // audio outlasts video
        let url = try await SyntheticVideoFixture.write(request, into: directory)
        let asset = AVURLAsset(url: url)

        let full = await NativeVideoPlayer.loopRange(of: asset, trim: nil)
        XCTAssertTrue(full.isValid)
        XCTAssertEqual(full.start.seconds, 0, accuracy: 0.002)
        XCTAssertEqual(full.duration.seconds, 2.0, accuracy: 0.002)

        let sub = try VideoTrimRange(startSeconds: 0.5, endSeconds: 1.5)
        let trimmed = await NativeVideoPlayer.loopRange(of: asset, trim: sub)
        XCTAssertTrue(trimmed.isValid)
        XCTAssertEqual(trimmed.start.seconds, 0.5, accuracy: 0.002)
        XCTAssertEqual(trimmed.duration.seconds, 1.0, accuracy: 0.002)

        let overEnd = try VideoTrimRange(startSeconds: 1.0, endSeconds: 9.0)
        let clamped = await NativeVideoPlayer.loopRange(of: asset, trim: overEnd)
        XCTAssertTrue(clamped.isValid)
        XCTAssertEqual(clamped.start.seconds, 1.0, accuracy: 0.002)
        XCTAssertEqual(clamped.duration.seconds, 1.0, accuracy: 0.002)

        let tooShort = try VideoTrimRange(startSeconds: 1.8, endSeconds: 4.0)
        let fallback = await NativeVideoPlayer.loopRange(of: asset, trim: tooShort)
        XCTAssertEqual(fallback.start.seconds, 0, accuracy: 0.002)
        XCTAssertEqual(fallback.duration.seconds, 2.0, accuracy: 0.002)
    }

    func testClampedSeekTimePreservesInRangeAndResetsOutOfRange() {
        let range = CMTimeRange(
            start: CMTime(seconds: 2.0, preferredTimescale: 600),
            duration: CMTime(seconds: 3.0, preferredTimescale: 600))
        let inside = NativeVideoPlayer.clampedSeekTime(CMTime(seconds: 3.2, preferredTimescale: 600), within: range)
        XCTAssertTrue(inside.isNumeric)
        XCTAssertEqual(inside.seconds, 3.2, accuracy: 0.001)

        let before = NativeVideoPlayer.clampedSeekTime(CMTime(seconds: 1.0, preferredTimescale: 600), within: range)
        XCTAssertFalse(before.isNumeric)

        let atEnd = NativeVideoPlayer.clampedSeekTime(CMTime(seconds: 5.0, preferredTimescale: 600), within: range)
        XCTAssertFalse(atEnd.isNumeric)
    }

    // MARK: - WebMFeeder A-B Loop & Keyframe Rewind

    func testWebMFeederStartsAtKeyframeBeforeStartMarksPrerollAndLoopsSeamlessly() throws {
        // WebMFixture.vp9 is 1.0s (30 frames @ 30fps) with keyframes at 0.0s and 0.5s.
        // Trimmed window [0.2, 0.8) has length 0.6s: pass 0 plays in [0.2, 0.8), pass 1 in [0.8, 1.4).
        let clip = try openWebM(WebMFixture.vp9)
        let feeder = WebMFeeder(file: clip, audio: nil, loopRange: 0.2...0.8)
        let sink = TrimRecordingSink(room: 64)
        XCTAssertTrue(feeder.feedVideo(into: sink))
        XCTAssertFalse(sink.buffers.isEmpty)

        // The first sample of pass 0 must be a keyframe (sync) with ResetDecoderBeforeDecoding.
        let firstAttachments = CMSampleBufferGetSampleAttachmentsArray(sink.buffers[0], createIfNecessary: false) as? [[CFString: Any]]
        XCTAssertNil(firstAttachments?.first?[kCMSampleAttachmentKey_NotSync])
        let resetAttachment = CMGetAttachment(
            sink.buffers[0], key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            attachmentModeOut: nil) as? Bool
        XCTAssertEqual(resetAttachment, true)

        // Because 0.2s lies after the 0.0s keyframe, preroll frames before 0.2s are marked DoNotDisplay.
        let prerollCount = sink.buffers.count - sink.visibleBuffers.count
        XCTAssertGreaterThan(prerollCount, 0, "frames before 0.2s should be fed as DoNotDisplay preroll")

        // Visible frames span strictly [0.2, 0.8) in pass 0 and [0.8, 1.4) in pass 1, continuing seamlessly.
        let visible = sink.visibleTimes
        XCTAssertGreaterThan(visible.count, 30, "should cover at least two trimmed passes")
        let pass0 = visible.filter { $0 < 0.8 - 0.001 }
        let pass1 = visible.filter { $0 >= 0.8 - 0.001 && $0 < 1.4 - 0.001 }
        XCTAssertFalse(pass0.isEmpty)
        XCTAssertFalse(pass1.isEmpty)
        XCTAssertEqual(pass0.min() ?? -1, 0.2, accuracy: 0.04)
        XCTAssertLessThan(pass0.max() ?? 99, 0.8 + 0.002)
        XCTAssertEqual(pass1.min() ?? -1, 0.8, accuracy: 0.04)
        XCTAssertLessThan(pass1.max() ?? 99, 1.4 + 0.002)
    }

    func testWebMFeederStartingOnKeyframeRequiresNoPrerollAndLoopsExactWindow() throws {
        // Keyframe 15 is at 0.5s: pass 0 plays in [0.5, 1.0), pass 1 in [1.0, 1.5).
        let clip = try openWebM(WebMFixture.vp9)
        let feeder = WebMFeeder(file: clip, audio: nil, loopRange: 0.5...1.0)
        let sink = TrimRecordingSink(room: 40)
        XCTAssertTrue(feeder.feedVideo(into: sink))

        let firstAttachments = CMSampleBufferGetSampleAttachmentsArray(sink.buffers[0], createIfNecessary: false) as? [[CFString: Any]]
        XCTAssertNil(firstAttachments?.first?[kCMSampleAttachmentKey_NotSync])

        let visible = sink.visibleTimes
        XCTAssertGreaterThan(visible.count, 20)
        XCTAssertEqual(visible.min() ?? -1, 0.5, accuracy: 0.04)
        let pass1 = visible.filter { $0 >= 1.0 - 0.001 && $0 < 1.5 - 0.001 }
        XCTAssertFalse(pass1.isEmpty)
        XCTAssertEqual(pass1.min() ?? -1, 1.0, accuracy: 0.04)
    }

    func testWebMFeederEndOfPassAndLiveLoopRangeUpdate() throws {
        let clip = try openWebM(WebMFixture.vp9)
        let end0 = try XCTUnwrap(WebMFeeder.endOfPass(
            containing: CMTime(seconds: 0.25, preferredTimescale: 1000),
            in: clip, loopRange: 0.2...0.8))
        XCTAssertEqual(end0.seconds, 0.8, accuracy: 0.002)

        let end1 = try XCTUnwrap(WebMFeeder.endOfPass(
            containing: CMTime(seconds: 0.9, preferredTimescale: 1000),
            in: clip, loopRange: 0.2...0.8))
        XCTAssertEqual(end1.seconds, 1.4, accuracy: 0.002)

        let feeder = WebMFeeder(file: clip, audio: nil, loopRange: nil)
        feeder.setLoopRange(0.2...0.8)
        feeder.reposition(at: CMTime(seconds: 0.2, preferredTimescale: 1000))
        let sink = TrimRecordingSink(room: 25)
        XCTAssertTrue(feeder.feedVideo(into: sink))
        XCTAssertFalse(sink.visibleTimes.isEmpty)
        XCTAssertEqual(sink.visibleTimes.min() ?? -1, 0.2, accuracy: 0.04)
    }

    func testWebMFeederAudioRespectsLoopWindowAndSubMinimumFallback() throws {
        let clip = try openWebM(Self.vp9Opus1200ms)
        let clipDuration = clip.duration.seconds
        XCTAssertGreaterThan(clipDuration, 1.0)

        // Sub-0.5s window falls back cleanly to the full clip window.
        let tooShortWindow = WebMFeeder.effectiveWindow(in: clip, loopRange: 0.1...0.4)
        XCTAssertFalse(tooShortWindow.isTrimmed)
        XCTAssertEqual(tooShortWindow.length.seconds, clipDuration, accuracy: 0.02)

        // Exercise a true trimmed sub-range (`isTrimmed == true`) NOT aligned to the 0.10s PCM
        // chunk boundaries, across multiple loop wraps.
        let trimRange = 0.25...0.85
        let window = WebMFeeder.effectiveWindow(in: clip, loopRange: trimRange)
        XCTAssertTrue(window.isTrimmed)
        let windowStart = window.start.seconds
        let windowLen = window.length.seconds
        XCTAssertEqual(windowLen, 0.60, accuracy: 0.005)

        let audio = try clip.makeAudioReader()
        let feeder = WebMFeeder(file: clip, audio: audio, loopRange: trimRange)
        let sink = TrimRecordingSink(room: 24)
        XCTAssertTrue(feeder.feedAudio(into: sink))
        XCTAssertGreaterThanOrEqual(sink.buffers.count, 16, "should span multiple trimmed audio passes")

        // Leading frames before 0.25s must be sliced off so audio begins at window.start.
        let firstStart = CMSampleBufferGetPresentationTimeStamp(sink.buffers[0]).seconds
        XCTAssertGreaterThanOrEqual(firstStart, windowStart - 1e-4)
        XCTAssertLessThan(firstStart, windowStart + 0.01)

        // PTS must be strictly monotonic and non-overlapping across every buffer and loop seam.
        var previousEnd = windowStart
        var maxEnd = 0.0
        for buffer in sink.buffers {
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let duration = CMSampleBufferGetDuration(buffer).seconds
            let end = start + duration
            XCTAssertGreaterThan(duration, 0)
            XCTAssertGreaterThanOrEqual(
                start, previousEnd - 1e-5,
                "trimmed audio overlapped or jumped backwards: start \(start) < prior end \(previousEnd)")
            let pass = floor((start - windowStart + 1e-4) / windowLen)
            let passStart = windowStart + pass * windowLen
            let passEnd = passStart + windowLen
            XCTAssertGreaterThanOrEqual(start, passStart - 1e-4)
            XCTAssertLessThanOrEqual(end, passEnd + 0.002)
            previousEnd = end
            maxEnd = max(maxEnd, end)
        }
        // Confirm at least two loop wraps occurred (into pass 2+).
        XCTAssertGreaterThan(maxEnd, windowStart + 2 * windowLen - 0.05)
    }

    func testWebMPlayerSetLoopRangeRepositionsPreStartAndHoldsClockDuringLiveUpdate() async throws {
        let clip = try openWebM(WebMFixture.vp9)

        // 1. Pre-start `setLoopRange` repositions both the clock and feeder to `window.start`.
        let preStartQueue = DispatchQueue(label: "test.webm.prestart")
        let preStart = WebMPlayer(
            file: clip, withAudio: false, paused: true, loopRange: nil, feedQueue: preStartQueue)
        defer { preStart.stop() }
        preStart.setLoopRange(0.2...0.8)
        XCTAssertEqual(preStart.loopRangeForTest, 0.2...0.8)
        XCTAssertEqual(preStart.currentTime.seconds, 0.2, accuracy: 0.01)
        preStart.start()
        let preStartDeadline = ContinuousClock.now + .seconds(2)
        while preStart.videoSamplesFed == 0 && ContinuousClock.now < preStartDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(preStart.videoSamplesFed, 0)
        XCTAssertEqual(preStart.currentTime.seconds, 0.2, accuracy: 0.01)

        // 2. Live `setLoopRange` after `start()` pauses the clock at `window.start` until the
        //    feed queue finishes repositioning, then restores the running rate.
        let gate = DispatchSemaphore(value: 0)
        var gateSignaled = false
        defer { if !gateSignaled { gate.signal() } }
        let gatedQueue = DispatchQueue(label: "test.webm.live-reposition")
        let live = WebMPlayer(
            file: clip, withAudio: false, paused: false, loopRange: nil, feedQueue: gatedQueue)
        defer { live.stop() }
        live.start()
        // Block the serial feed queue behind an already-scheduled barrier so we can observe the
        // player's clock state while `setLoopRange`'s reposition is in flight.
        gatedQueue.async { gate.wait() }
        live.setLoopRange(0.25...0.85)
        XCTAssertEqual(live.synchronizerRateForTest, 0, "clock must stay paused until reposition completes")
        XCTAssertEqual(live.currentTime.seconds, 0.25, accuracy: 0.01)

        gateSignaled = true
        gate.signal()
        let resumeDeadline = ContinuousClock.now + .seconds(2)
        while live.synchronizerRateForTest == 0 && ContinuousClock.now < resumeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(live.synchronizerRateForTest, 1.0, accuracy: 0.001)
    }

    func testWebMFeederClampsBFrameDTSMonotonicallyAcrossPrerollAndWraps() throws {
        let clip = try openWebM(Self.h264BFrames1s)
        let feeder = WebMFeeder(file: clip, audio: nil, loopRange: 0.2...0.8)
        let sink = TrimRecordingSink(room: 80)
        XCTAssertTrue(feeder.feedVideo(into: sink))
        XCTAssertFalse(sink.visibleBuffers.isEmpty)

        // Must cover pass 0 ([0.2, 0.8)) and pass 1 ([0.8, 1.4)).
        let pass0Visible = sink.visibleTimes.filter { $0 < 0.8 - 0.001 }
        let pass1Visible = sink.visibleTimes.filter { $0 >= 0.8 - 0.001 && $0 < 1.4 - 0.001 }
        XCTAssertFalse(pass0Visible.isEmpty)
        XCTAssertFalse(pass1Visible.isEmpty)

        // Every emitted sample's DTS must be monotonically non-decreasing (no backward jump from
        // preroll into the first visible B-frame-reordered sample or across loop wraps).
        var previousDTS = CMTime.negativeInfinity
        for buffer in sink.buffers {
            let dts = CMSampleBufferGetDecodeTimeStamp(buffer)
            guard dts.isNumeric else { continue }
            if previousDTS.isNumeric {
                XCTAssertGreaterThanOrEqual(
                    CMTimeCompare(dts, previousDTS), 0,
                    "DTS jumped backwards from \(previousDTS.seconds) to \(dts.seconds)")
            }
            previousDTS = dts
        }
        for buffer in sink.visibleBuffers {
            let dts = CMSampleBufferGetDecodeTimeStamp(buffer)
            if dts.isNumeric {
                XCTAssertGreaterThanOrEqual(dts.seconds, 0.2 - 1e-4)
            }
        }
    }

    func testWebMFeederEmptyTrimWindowFallsBackToFullClipInsteadOfBlackScreen() throws {
        // 1 fps, 3-second clip (frames at 0.0s, 1.0s, 2.0s): [0.2, 0.8) contains zero visible frames.
        let clip = try openWebM(Self.vp9OneFps3s)
        let window = WebMFeeder.effectiveWindow(in: clip, loopRange: 0.2...0.8)
        XCTAssertTrue(window.isTrimmed)

        let feeder = WebMFeeder(file: clip, audio: nil, loopRange: 0.2...0.8)
        let failureDetail = OSAllocatedUnfairLock<String?>(initialState: nil)
        feeder.onFailure = { detail in failureDetail.withLock { $0 = detail } }

        let sink = TrimRecordingSink(room: 10)
        XCTAssertTrue(feeder.feedVideo(into: sink), "empty trim window must fall back to full clip, not halt")
        XCTAssertNil(failureDetail.withLock { $0 })
        XCTAssertGreaterThanOrEqual(sink.visibleBuffers.count, 4, "fallback must keep emitting visible frames")

        // Emitted timestamps must stay monotonically non-decreasing across the fallback transition.
        var previousDTS = CMTime.negativeInfinity
        for buffer in sink.buffers {
            let dts = CMSampleBufferGetDecodeTimeStamp(buffer)
            if dts.isNumeric, previousDTS.isNumeric {
                XCTAssertGreaterThanOrEqual(CMTimeCompare(dts, previousDTS), 0)
            }
            if dts.isNumeric { previousDTS = dts }
        }
        for (a, b) in zip(sink.visibleTimes, sink.visibleTimes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b, a - 1e-5)
        }
    }

    func testVideoTrimCardClampAfterRoundAlwaysProducesValidTrimRange() throws {
        // Clips whose duration ends in .x5–.x9 previously rounded up past the 0.5s minimum span.
        for duration in [10.06, 10.05, 10.09, 10.04, 1.26, 0.5] {
            let startAtMax = VideoTrimCard.clampedStart(duration, currentEnd: duration, duration: duration)
            XCTAssertGreaterThanOrEqual(startAtMax, 0)
            XCTAssertLessThanOrEqual(startAtMax, duration - VideoTrimRange.minimumDuration + 1e-9)
            XCTAssertNoThrow(try VideoTrimRange(startSeconds: startAtMax, endSeconds: duration))

            let endAtMin = VideoTrimCard.clampedEnd(startAtMax, currentStart: startAtMax, duration: duration)
            XCTAssertLessThanOrEqual(endAtMin, duration + 1e-9)
            XCTAssertGreaterThanOrEqual(endAtMin, startAtMax + VideoTrimRange.minimumDuration - 1e-9)
            XCTAssertNoThrow(try VideoTrimRange(startSeconds: startAtMax, endSeconds: endAtMin))

            let endAtMax = VideoTrimCard.clampedEnd(duration, currentStart: 0, duration: duration)
            XCTAssertLessThanOrEqual(endAtMax, duration)
            XCTAssertNoThrow(try VideoTrimRange(startSeconds: 0, endSeconds: endAtMax))
        }

        // Regression case cited in review: 10.06s clip dragging Start past 9.56s must clamp to 9.56, not 9.6.
        let clamped = VideoTrimCard.clampedStart(9.6, currentEnd: 10.06, duration: 10.06)
        XCTAssertEqual(clamped, 9.56, accuracy: 1e-9)
        XCTAssertNoThrow(try VideoTrimRange(startSeconds: clamped, endSeconds: 10.06))
    }

    func testNativeVideoPlayerInitialTrimAppliesBeforeFirstLooperStart() async throws {
        let request = SyntheticVideoFixture.Request.constantRate(
            name: "trim-initial-single-looper", numerator: 30, denominator: 1, frames: 60)
        let url = try await SyntheticVideoFixture.write(request, into: directory)
        let surface = RuntimeSurfaceKey(kind: .desktopNativeVideo, displayID: 1, generation: 1)
        let counters = RuntimeCounters()
        counters.startSession(duration: .seconds(60))
        let player = NativeVideoPlayer(surface: surface, counters: counters, paused: true)
        defer { player.stop() }

        // Mirror `NativeVideoWallpaperHost.open`: `load` starts, then `update` sets the saved trim
        // synchronously before `load`'s async metadata read completes.
        player.load(url: url)
        player.setTrimRange(try VideoTrimRange(startSeconds: 0.5, endSeconds: 1.5))

        let deadline = ContinuousClock.now + .seconds(3)
        while !player.activeLoopRangeForTest.isValid && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(player.activeLoopRangeForTest.isValid)
        XCTAssertEqual(player.activeLoopRangeForTest.start.seconds, 0.5, accuracy: 0.02)
        XCTAssertEqual(player.activeLoopRangeForTest.duration.seconds, 1.0, accuracy: 0.02)
        XCTAssertEqual(
            counters.snapshot().value(.nativeVideoItemCreated, for: surface), 1,
            "initial trim should be applied before creating the first AVPlayerLooper (no frame-0 flash)")
    }

    // MARK: - Embedded Compact Test Fixtures

    /// 128x96 15fps VP9 + 48kHz stereo Opus, 1.2s, for exercising trimmed audio (`isTrimmed == true`).
    private static let vp9Opus1200ms: Data = Data(
        base64Encoded: """
            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
            """,
        options: .ignoreUnknownCharacters)!

    /// 128x96 1fps VP9, 3 frames (at 0s, 1s, 2s; 3.0s total) — trim [0.2, 0.8) has zero visible frames.
    private static let vp9OneFps3s: Data = Data(
        base64Encoded: """
            GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAIxEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHWTbuMU6uEElTDZ1OsggEyTbuMU6uEHFO7a1OsggIb7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxMYXZmNjMuMS4xMDJXQYxMYXZmNjMuMS4xMDJEiYhAp3AAAAAAABZUrmvXrgEAAAAAAABO14EBc8WIIi7pynk+cu2cgQAitZyDdW5kiIEAhoVWX1ZQOYOBASPjg4Q7msoA4JCwgYC6gWCagQJVsIRVuYEBVe6BAOwBAAAAAAAAAgAAElTDZ/5zc59jwIBnyJlFo4dFTkNPREVSRIeMTGF2ZjYzLjEuMTAyc3PZY8CLY8WIIi7pynk+cu1nyKRFo4dFTkNPREVSRIeXTGF2YzYzLjEuMTAyIGxpYnZweC12cDlnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAzLjAwMDAwMDAwMAAfQ7Z14eeBAKOwgQAAgIJJg0IAB/AF9gY4JBwYQgAAMGAAAGc///5plf////6E6/////4O0dRUjNOAo5SBA+gAhgBAkpwoSUAAA3AAAFn8LKOUgQfQAIYAQJKcLErAAANwAABZ/CwcU7trkbuPs4EAt4r3gQHxggG18IED
            """,
        options: .ignoreUnknownCharacters)!

    /// 128x96 30fps H.264 Matroska with B-frames (`-bf 2`, `b-adapt=0`, 1.0s) where visible frames
    /// near `0.2s` carry `dts < 0.2s` to exercise monotonic DTS clamping after preroll.
    private static let h264BFrames1s: Data = Data(
        base64Encoded: """
            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
            """,
        options: .ignoreUnknownCharacters)!

    // MARK: - VideoTrimStore Persistence & Backup Validation

    func testVideoTrimStorePersistsClearsForgetsAndNotifies() throws {
        let (defaults, _) = try TemporaryDefaults.make(for: self)
        let store = VideoTrimStore(defaults: defaults)
        var notifiedIDs: [String?] = []
        let observer = NotificationCenter.default.addObserver(
            forName: VideoTrimStore.didChangeNotification, object: store, queue: .main
        ) { notification in
            notifiedIDs.append(notification.userInfo?[VideoTrimStore.wallpaperIDUserInfoKey] as? String)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let range = try VideoTrimRange(startSeconds: 1.5, endSeconds: 8.2)
        try store.set(range, for: "video-1")
        XCTAssertEqual(store.trimRange(for: "video-1"), range)
        XCTAssertEqual(notifiedIDs, ["video-1"])

        // Reloading from the same UserDefaults restores saved ranges.
        let reloaded = VideoTrimStore(defaults: defaults)
        XCTAssertEqual(reloaded.trimRange(for: "video-1"), range)

        // Invalid wallpaper IDs are refused.
        XCTAssertThrowsError(try store.set(range, for: ""))
        XCTAssertThrowsError(try store.set(range, for: "../escape"))

        // Clear removes only that wallpaper and notifies.
        try store.clear(for: "video-1")
        XCTAssertNil(store.trimRange(for: "video-1"))
        XCTAssertEqual(notifiedIDs, ["video-1", "video-1"])

        // Forget cleans up multiple deleted wallpapers.
        try store.set(range, for: "video-a")
        try store.set(range, for: "video-b")
        try store.forget(["video-a"])
        XCTAssertNil(store.trimRange(for: "video-a"))
        XCTAssertEqual(store.trimRange(for: "video-b"), range)

        // Backup archive validation accepts saved data and rejects corrupt payloads.
        let savedData = try XCTUnwrap(defaults.data(forKey: VideoTrimStore.storageKey))
        XCTAssertNoThrow(try VideoTrimStore.validateArchiveData(savedData))
        XCTAssertThrowsError(try VideoTrimStore.validateArchiveData(Data(#"{"version":99,"ranges":{}}"#.utf8)))
        XCTAssertThrowsError(try VideoTrimStore.validateArchiveData(
            Data(#"{"version":1,"ranges":{"../bad":{"startSeconds":0,"endSeconds":2}}}"#.utf8)))
        XCTAssertThrowsError(try VideoTrimStore.validateArchiveData(
            Data(#"{"version":1,"ranges":{"ok":{"startSeconds":2,"endSeconds":2.1}}}"#.utf8)))
    }
}

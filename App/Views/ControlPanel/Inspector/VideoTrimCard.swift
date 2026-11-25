import SwiftUI

/// Loop trim card in the Installed inspector for video wallpapers: lets the user set Start and End
/// points (with `MM:SS.t` readout and a minimum 0.5-second loop span) or reset to the full clip.
///
/// Zero disk or decoder work runs in `body`: duration metadata loads asynchronously via `.task`,
/// and edits persist through typed `PanelController` actions via `launch`.
struct VideoTrimCard: View {
  let state: VideoTrimState

  @Environment(PanelController.self) private var controller
  @Environment(\.panelTheme) private var theme
  @State private var draftStart: Double?
  @State private var draftEnd: Double?
  @State private var commitToken = 0

  var body: some View {
    let shownStart = draftStart ?? state.effectiveStart
    let shownEnd = draftEnd ?? state.effectiveEnd
    InspectorSection(
      "Loop trim",
      accessory: {
        if state.isTrimmed, state.canTrim {
          Text(verbatim: "\(VideoTrimRange.formatTimestamp(shownStart)) – \(VideoTrimRange.formatTimestamp(shownEnd))")
            .font(.panel(.caption).monospacedDigit())
            .foregroundStyle(theme.accent.accent.color)
        }
      }
    ) {
      if state.isLoadingDuration {
        InspectorCardRow {
          HStack(spacing: 8) {
            ProgressRing(value: nil, lineWidth: 1.5).frame(width: 12, height: 12)
            Text("Reading video duration…")
              .font(.panel(.footnote))
              .foregroundStyle(theme.surface.muted.color)
          }
        }
      } else if state.durationFailed {
        InspectorCardRow {
          InspectorNote("This video’s duration could not be read.")
        }
      } else if state.isTooShort {
        InspectorCardRow {
          InspectorNote("This video is too short to trim.")
        }
      } else if let duration = state.durationSeconds, state.canTrim {
        trimControls(duration: duration, shownStart: shownStart, shownEnd: shownEnd)
      } else {
        InspectorCardRow {
          HStack(spacing: 8) {
            ProgressRing(value: nil, lineWidth: 1.5).frame(width: 12, height: 12)
            Text("Reading video duration…")
              .font(.panel(.footnote))
              .foregroundStyle(theme.surface.muted.color)
          }
        }
      }
    }
    .task(id: "\(state.wallpaperID):\(state.displayID)") {
      commitToken += 1
      draftStart = nil
      draftEnd = nil
      await controller.loadVideoTrimDuration(for: state.wallpaperID, display: state.displayID)
    }
    .onChange(of: state.savedRange) { _, _ in
      commitToken += 1
      draftStart = nil
      draftEnd = nil
    }
  }

  @ViewBuilder
  private func trimControls(duration: Double, shownStart: Double, shownEnd: Double) -> some View {
    let minSpan = VideoTrimRange.minimumDuration
    let clampedStart = max(0, min(shownStart, max(0, duration - minSpan)))
    let clampedEnd = min(duration, max(shownEnd, min(duration, clampedStart + minSpan)))
    let loopSpan = max(0, clampedEnd - clampedStart)
    let actionKey = PanelActionCoordinator.key("videoTrim", id: state.wallpaperID)

    InspectorCardRow {
      VStack(alignment: .leading, spacing: 8) {
        TrimRangeBar(start: clampedStart, end: clampedEnd, duration: duration)
        HStack(spacing: 8) {
          Text("Loop length")
            .font(.panel(.footnote))
            .foregroundStyle(theme.surface.muted.color)
          Spacer(minLength: 4)
          Text(verbatim: VideoTrimRange.formatTimestamp(loopSpan))
            .font(.panel(.footnote).monospacedDigit())
            .foregroundStyle(theme.surface.text.color)
        }
      }
    }

    let maxStart = max(0, clampedEnd - minSpan)
    let minEnd = min(duration, clampedStart + minSpan)
    let canMoveStart = maxStart > 0
    let canMoveEnd = minEnd < duration

    InspectorSliderRow(
      title: "Start",
      value: clampedStart,
      range: 0...max(0.1, maxStart),
      step: 0.1,
      accessibilityLabel: L("Start"),
      format: { VideoTrimRange.formatTimestamp(Self.clampedStart($0, currentEnd: clampedEnd, duration: duration)) },
      onDrag: { raw in
        commitToken += 1
        let bounded = Self.clampedStart(raw, currentEnd: clampedEnd, duration: duration)
        draftStart = bounded
        if draftEnd == nil { draftEnd = clampedEnd }
      },
      onRelease: { raw in
        let bounded = Self.clampedStart(raw, currentEnd: clampedEnd, duration: duration)
        draftStart = bounded
        draftEnd = clampedEnd
        return commit(start: bounded, end: clampedEnd, key: actionKey)
      },
      onStep: { raw in
        let bounded = Self.clampedStart(raw, currentEnd: clampedEnd, duration: duration)
        draftStart = bounded
        draftEnd = clampedEnd
        return commit(start: bounded, end: clampedEnd, key: actionKey)
      }
    )
    .disabled(!canMoveStart)
    .accessibilityIdentifier("inspector.videoTrim.start")

    InspectorSliderRow(
      title: "End",
      value: clampedEnd,
      range: (canMoveEnd ? minEnd : max(0, duration - 0.1))...duration,
      step: 0.1,
      accessibilityLabel: L("End"),
      format: { VideoTrimRange.formatTimestamp(Self.clampedEnd($0, currentStart: clampedStart, duration: duration)) },
      onDrag: { raw in
        commitToken += 1
        let bounded = Self.clampedEnd(raw, currentStart: clampedStart, duration: duration)
        draftEnd = bounded
        if draftStart == nil { draftStart = clampedStart }
      },
      onRelease: { raw in
        let bounded = Self.clampedEnd(raw, currentStart: clampedStart, duration: duration)
        draftStart = clampedStart
        draftEnd = bounded
        return commit(start: clampedStart, end: bounded, key: actionKey)
      },
      onStep: { raw in
        let bounded = Self.clampedEnd(raw, currentStart: clampedStart, duration: duration)
        draftStart = clampedStart
        draftEnd = bounded
        return commit(start: clampedStart, end: bounded, key: actionKey)
      }
    )
    .disabled(!canMoveEnd)
    .accessibilityIdentifier("inspector.videoTrim.end")

    InspectorCardRow {
      VStack(alignment: .leading, spacing: 6) {
        Button {
          commitToken += 1
          draftStart = nil
          draftEnd = nil
          controller.launch(actionKey, policy: .latestWins) {
            try await controller.resetVideoTrim(state.wallpaperID)
          }
        } label: {
          Label("Reset to full clip", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.panelCardLink)
        .disabled(!state.isTrimmed || controller.isBusy(actionKey))
        .help(L("Play the full video from start to finish"))
        .accessibilityIdentifier("inspector.videoTrim.reset")
        InspectorNote("Plays only the selected portion in a loop. Changes apply immediately.")
      }
    }
  }

  private func commit(start: Double, end: Double, key: String) -> Task<Void, Never> {
    let wallpaperID = state.wallpaperID
    commitToken += 1
    let token = commitToken
    let task = controller.launch(key, policy: .latestWins) {
      try await controller.setVideoTrim(wallpaperID, startSeconds: start, endSeconds: end)
    }
    // Always clear local drafts after commit finishes (including no-op or failed commits where
    // `state.savedRange` does not change) unless a newer drag or commit began meanwhile.
    Task { @MainActor in
      await task.value
      if commitToken == token {
        draftStart = nil
        draftEnd = nil
      }
    }
    return task
  }

  /// Rounds to 0.1s first, then clamps strictly within `[0, min(duration, currentEnd) - 0.5]` so
  /// rounding can never shrink the loop below `VideoTrimRange.minimumDuration` (e.g. a `10.06s` clip).
  static func clampedStart(_ value: Double, currentEnd: Double, duration: Double) -> Double {
    guard duration.isFinite, duration > 0 else { return 0 }
    let effectiveEnd = min(duration, currentEnd.isFinite ? currentEnd : duration)
    let upper = max(0, effectiveEnd - VideoTrimRange.minimumDuration)
    let rounded = value.isFinite ? (value * 10).rounded() / 10 : 0
    return max(0, min(rounded, upper))
  }

  /// Rounds to 0.1s first, then clamps strictly within `[currentStart + 0.5, duration]` so
  /// rounding can never shrink the loop below `VideoTrimRange.minimumDuration` or exceed `duration`.
  static func clampedEnd(_ value: Double, currentStart: Double, duration: Double) -> Double {
    guard duration.isFinite, duration > 0 else { return 0 }
    let effectiveStart = max(0, min(duration, currentStart.isFinite ? currentStart : 0))
    let lower = min(duration, effectiveStart + VideoTrimRange.minimumDuration)
    let rounded = value.isFinite ? (value * 10).rounded() / 10 : duration
    return min(duration, max(rounded, lower))
  }
}

/// Compact range indicator highlighting `[start, end]` within the clip's total duration.
private struct TrimRangeBar: View {
  let start: Double
  let end: Double
  let duration: Double

  @Environment(\.panelTheme) private var theme

  var body: some View {
    GeometryReader { proxy in
      let width = max(1, proxy.size.width)
      let startFraction = duration > 0 ? max(0, min(1, start / duration)) : 0
      let endFraction = duration > 0 ? max(startFraction, min(1, end / duration)) : 1
      let barX = width * startFraction
      let barWidth = max(4, width * (endFraction - startFraction))
      ZStack(alignment: .leading) {
        Capsule()
          .fill(theme.surface.well.color)
          .frame(height: 6)
        Capsule()
          .fill(theme.accent.accent.color)
          .frame(width: min(barWidth, max(0, width - barX)), height: 6)
          .offset(x: barX)
      }
    }
    .frame(height: 6)
    .accessibilityHidden(true)
  }
}

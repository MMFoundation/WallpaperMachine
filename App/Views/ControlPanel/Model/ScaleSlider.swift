import Foundation

/// The Scale percentage slider of a display, in the inspector's display card and in Settings › Displays: the
/// scale factor as a whole percentage, for shrinking a wallpaper below the size its scaling mode
/// gives it. It writes the same number as the Scale factor field beside it, which keeps every value
/// the slider does not offer (a factor above 1, a fraction of a percent).
enum ScaleSlider {
  /// The percentages the slider offers.
  static let range: ClosedRange<Double> = 10...100

  /// Where the thumb sits for `factor`: its whole percentage, held to the range, so a factor above
  /// 1 is the top of the slider. A factor that is not a number reads as 100%.
  static func percent(for factor: Double) -> Double {
    guard factor.isFinite else { return range.upperBound }
    return min(range.upperBound, max(range.lowerBound, (factor * 100).rounded()))
  }

  /// The scale factor a thumb at `percent` asks for, or nil when the thumb sits where `current`
  /// already puts it: a click that moves nothing must not turn 1.34 into 1.
  static func factor(for percent: Double, current: Double) -> Double? {
    let percent = min(range.upperBound, max(range.lowerBound, percent.rounded()))
    return percent == self.percent(for: current) ? nil : percent / 100
  }
}

import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import QuartzCore

/// Keeps actual frame pixels in the remote layer tree when no Metal drawable is available.
enum LockScreenFrameBacking {
  static func install(_ surface: IOSurface, on root: CALayer) throws {
      // CLEANROOM A46: implement from specs/app/a1-app-remnants.md
      fatalError("CLEANROOM A46")
  }
}

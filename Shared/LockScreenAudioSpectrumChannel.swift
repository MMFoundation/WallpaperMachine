import Darwin
import Foundation
import Synchronization

/// Shared-memory seqlock channel for forwarding 224-band system-audio spectra from the
/// main app to the sandboxed lock-screen / screen-saver extension without disk flushes.
///
/// The backing file (`LockScreenExchange/audio-spectrum.shm`, 4096 bytes) is `mmap`'d
/// `MAP_SHARED` by both processes and never `msync`'d, so 30 Hz updates stay in RAM.
enum LockScreenAudioSpectrumChannel {
  static let fileName = "audio-spectrum.shm"
  static let byteSize = 4096
  static let magic: UInt32 = 0x5541_4D57 // "WMAU"
  static let version: UInt32 = 1
  /// Full spectrum: `left64, right64, left32, right32, left16, right16` (unclamped).
  static let bandCount = 224
  /// First 128 floats (`left64, right64`), clamped to `[0, 1]` for Web wallpapers.
  static let webBinCount = 128
  /// Matches `AudioResponseService`'s 250 ms staleness window.
  static let defaultStaleNanoseconds: UInt64 = 250_000_000

  // Fixed byte offsets inside the 4096-byte page (naturally aligned).
  fileprivate static let offsetMagic = 0
  fileprivate static let offsetVersion = 4
  fileprivate static let offsetSeq = 8
  fileprivate static let offsetGeneration = 16
  fileprivate static let offsetTimestampNanos = 24
  fileprivate static let offsetStereo = 32
  fileprivate static let offsetActive = 36
  fileprivate static let offsetBands = 40

  static func nowNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  }

  static func url(in exchange: URL) -> URL {
    exchange.appendingPathComponent(fileName)
  }
}

struct LockScreenAudioSpectrumFrame: Equatable, Sendable {
  var generation: UInt64
  var stereo: Bool
  /// Always 224 floats (`left64, right64, left32, right32, left16, right16`), unclamped.
  var bands: [Float]

  /// First 128 floats (`left64, right64`), sanitized and clamped to `[0, 1]` for
  /// Wallpaper Engine's `wallpaperRegisterAudioListener`.
  func clampedWebBins128() -> [Double] {
    var result = [Double](repeating: 0, count: LockScreenAudioSpectrumChannel.webBinCount)
    let limit = min(bands.count, LockScreenAudioSpectrumChannel.webBinCount)
    for index in 0..<limit {
      let value = bands[index]
      result[index] = value.isFinite ? Double(min(max(value, 0), 1)) : 0
    }
    return result
  }
}

/// Main-app writer for `audio-spectrum.shm`. Single-writer seqlock; never calls `msync`.
final class LockScreenAudioSpectrumWriter {
  private let url: URL
  private var mapping: UnsafeMutableRawPointer?
  private var localSeq: UInt64 = 0

  init(exchange: URL) {
    self.url = LockScreenAudioSpectrumChannel.url(in: exchange)
  }

  deinit {
    unmap()
  }

  @discardableResult
  func openIfNeeded() -> Bool {
    if mapping != nil { return true }
    let parent = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
    guard ftruncate(fd, off_t(LockScreenAudioSpectrumChannel.byteSize)) == 0 else { return false }
    let raw = mmap(
      nil, LockScreenAudioSpectrumChannel.byteSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    guard raw != MAP_FAILED, let base = raw else { return false }
    memset(base, 0, LockScreenAudioSpectrumChannel.byteSize)
    base.storeBytes(
      of: LockScreenAudioSpectrumChannel.magic,
      toByteOffset: LockScreenAudioSpectrumChannel.offsetMagic, as: UInt32.self)
    base.storeBytes(
      of: LockScreenAudioSpectrumChannel.version,
      toByteOffset: LockScreenAudioSpectrumChannel.offsetVersion, as: UInt32.self)
    atomicMemoryFence(ordering: .releasing)
    mapping = base
    localSeq = 0
    return true
  }

  /// Publishes one full 224-band spectrum frame into shared memory.
  @discardableResult
  func write(
    generation: UInt64,
    stereo: Bool,
    bands: [Float],
    nowNanos: UInt64 = LockScreenAudioSpectrumChannel.nowNanoseconds()
  ) -> Bool {
    guard bands.count == LockScreenAudioSpectrumChannel.bandCount else { return false }
    guard openIfNeeded(), let base = mapping else { return false }
    localSeq &+= 1 // odd: write in progress
    base.storeBytes(
      of: localSeq, toByteOffset: LockScreenAudioSpectrumChannel.offsetSeq, as: UInt64.self)
    atomicMemoryFence(ordering: .releasing)

    base.storeBytes(
      of: generation, toByteOffset: LockScreenAudioSpectrumChannel.offsetGeneration, as: UInt64.self)
    base.storeBytes(
      of: nowNanos, toByteOffset: LockScreenAudioSpectrumChannel.offsetTimestampNanos, as: UInt64.self)
    base.storeBytes(
      of: UInt32(stereo ? 1 : 0), toByteOffset: LockScreenAudioSpectrumChannel.offsetStereo, as: UInt32.self)
    base.storeBytes(
      of: UInt32(1), toByteOffset: LockScreenAudioSpectrumChannel.offsetActive, as: UInt32.self)
    let dest = base.advanced(by: LockScreenAudioSpectrumChannel.offsetBands)
    bands.withUnsafeBytes { source in
      if let srcBase = source.baseAddress {
        memcpy(dest, srcBase, LockScreenAudioSpectrumChannel.bandCount * MemoryLayout<Float>.stride)
      }
    }

    atomicMemoryFence(ordering: .releasing)
    localSeq &+= 1 // even: stable
    base.storeBytes(
      of: localSeq, toByteOffset: LockScreenAudioSpectrumChannel.offsetSeq, as: UInt64.self)
    return true
  }

  /// Marks the shared page inactive so any live reader immediately stops reading, unmaps it,
  /// and optionally removes the backing file.
  func deactivate(removeFile: Bool = true) {
    if let base = mapping {
      localSeq &+= 1
      base.storeBytes(
        of: localSeq, toByteOffset: LockScreenAudioSpectrumChannel.offsetSeq, as: UInt64.self)
      atomicMemoryFence(ordering: .releasing)
      base.storeBytes(
        of: UInt64(0), toByteOffset: LockScreenAudioSpectrumChannel.offsetGeneration, as: UInt64.self)
      base.storeBytes(
        of: UInt32(0), toByteOffset: LockScreenAudioSpectrumChannel.offsetActive, as: UInt32.self)
      memset(
        base.advanced(by: LockScreenAudioSpectrumChannel.offsetBands), 0,
        LockScreenAudioSpectrumChannel.bandCount * MemoryLayout<Float>.stride)
      atomicMemoryFence(ordering: .releasing)
      localSeq &+= 1
      base.storeBytes(
        of: localSeq, toByteOffset: LockScreenAudioSpectrumChannel.offsetSeq, as: UInt64.self)
      unmap()
    }
    if removeFile {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func unmap() {
    if let base = mapping {
      munmap(base, LockScreenAudioSpectrumChannel.byteSize)
      mapping = nil
    }
  }
}

/// Extension-side read-only seqlock consumer for `audio-spectrum.shm`.
///
/// Zero syscalls on the 30 Hz hot path while the stream is active and fresh. Only checks
/// `stat` to re-map if unmapped, inactive, or stale (handling file removal and recreation).
final class LockScreenAudioSpectrumReader {
  private struct FileIdentity: Equatable {
    var device: dev_t
    var inode: ino_t
  }

  private let url: URL
  private var mapping: UnsafeRawPointer?
  private var identity: FileIdentity?

  init(exchange: URL) {
    self.url = LockScreenAudioSpectrumChannel.url(in: exchange)
  }

  deinit {
    close()
  }

  func close() {
    if let base = mapping {
      munmap(UnsafeMutableRawPointer(mutating: base), LockScreenAudioSpectrumChannel.byteSize)
      mapping = nil
    }
    identity = nil
  }

  func read(
    nowNanos: UInt64 = LockScreenAudioSpectrumChannel.nowNanoseconds(),
    maxAgeNanos: UInt64 = LockScreenAudioSpectrumChannel.defaultStaleNanoseconds
  ) -> LockScreenAudioSpectrumFrame? {
    if mapping == nil, !reopenIfChanged() {
      return nil
    }
    if let frame = sampleCurrentMapping(nowNanos: nowNanos, maxAgeNanos: maxAgeNanos) {
      return frame
    }
    // Inactive, stale or invalid: check once whether the writer replaced the file.
    if reopenIfChanged() {
      return sampleCurrentMapping(nowNanos: nowNanos, maxAgeNanos: maxAgeNanos)
    }
    return nil
  }

  private func sampleCurrentMapping(
    nowNanos: UInt64, maxAgeNanos: UInt64
  ) -> LockScreenAudioSpectrumFrame? {
    guard let base = mapping else { return nil }
    var bands = [Float](repeating: 0, count: LockScreenAudioSpectrumChannel.bandCount)
    for _ in 0..<4 {
      let magic = base.load(
        fromByteOffset: LockScreenAudioSpectrumChannel.offsetMagic, as: UInt32.self)
      let version = base.load(
        fromByteOffset: LockScreenAudioSpectrumChannel.offsetVersion, as: UInt32.self)
      guard magic == LockScreenAudioSpectrumChannel.magic,
        version == LockScreenAudioSpectrumChannel.version
      else { return nil }

      let seq1 = base.load(
        fromByteOffset: LockScreenAudioSpectrumChannel.offsetSeq, as: UInt64.self)
      atomicMemoryFence(ordering: .acquiring)
      if (seq1 & 1) != 0 { continue }

      let generation = base.load(
        fromByteOffset: LockScreenAudioSpectrumChannel.offsetGeneration, as: UInt64.self)
      let timestampNanos = base.load(
        fromByteOffset: LockScreenAudioSpectrumChannel.offsetTimestampNanos, as: UInt64.self)
      let stereoRaw = base.load(
        fromByteOffset: LockScreenAudioSpectrumChannel.offsetStereo, as: UInt32.self)
      let activeRaw = base.load(
        fromByteOffset: LockScreenAudioSpectrumChannel.offsetActive, as: UInt32.self)
      let src = base.advanced(by: LockScreenAudioSpectrumChannel.offsetBands)
      bands.withUnsafeMutableBytes { dest in
        if let destBase = dest.baseAddress {
          memcpy(destBase, src, LockScreenAudioSpectrumChannel.bandCount * MemoryLayout<Float>.stride)
        }
      }

      atomicMemoryFence(ordering: .acquiring)
      let seq2 = base.load(
        fromByteOffset: LockScreenAudioSpectrumChannel.offsetSeq, as: UInt64.self)
      if seq1 != seq2 { continue }

      guard activeRaw == 1, generation > 0 else { return nil }
      if nowNanos > timestampNanos, nowNanos - timestampNanos > maxAgeNanos {
        return nil
      }
      return LockScreenAudioSpectrumFrame(
        generation: generation, stereo: stereoRaw == 1, bands: bands)
    }
    return nil
  }

  /// Re-opens the mapping if the file on disk appeared, disappeared, or changed inode.
  /// Returns `true` when a new mapping was installed.
  @discardableResult
  private func reopenIfChanged() -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size >= off_t(LockScreenAudioSpectrumChannel.byteSize)
    else {
      close()
      return false
    }
    let nextIdentity = FileIdentity(device: info.st_dev, inode: info.st_ino)
    if nextIdentity == identity, mapping != nil {
      return false
    }
    close()
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    var fdInfo = stat()
    guard fstat(fd, &fdInfo) == 0,
      (fdInfo.st_mode & S_IFMT) == S_IFREG,
      fdInfo.st_size >= off_t(LockScreenAudioSpectrumChannel.byteSize)
    else { return false }
    let raw = mmap(
      nil, LockScreenAudioSpectrumChannel.byteSize, PROT_READ, MAP_SHARED, fd, 0)
    guard raw != MAP_FAILED, let base = raw else { return false }
    mapping = UnsafeRawPointer(base)
    identity = FileIdentity(device: fdInfo.st_dev, inode: fdInfo.st_ino)
    return true
  }
}

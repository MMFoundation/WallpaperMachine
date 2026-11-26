import Darwin
import Foundation

struct LockScreenSceneLayerRequest: Codable, Hashable, Sendable {
  let token: UUID
  let revision: String
  let displayID: UInt32
  let content: LockScreenContent
}

enum LockScreenSceneLayerExchange {
  static let fileName = "scene-layer-state.json"
  static let changedNotification = "app.wallpapermachine.lock-screen.scene-layers.changed"
  static let maximumRequests = 32
  static let maximumStateBytes = 64 * 1024
  private static let maximumFileBytes = maximumRequests * (2 * maximumStateBytes + 64)

  static func read(from exchange: URL) -> [UUID: String] {
    let url = exchange.appendingPathComponent(fileName)
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return [:] }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size > 0, info.st_size <= maximumFileBytes,
      let data = try? file.read(upToCount: Int(info.st_size) + 1), data.count == info.st_size,
      let records = try? JSONDecoder().decode([String: String].self, from: data),
      records.count <= maximumRequests
    else { return [:] }
    var states: [UUID: String] = [:]
    for (key, state) in records {
      guard key.utf8.count == 36, let token = UUID(uuidString: key), valid(state),
        states.updateValue(state, forKey: token) == nil
      else { return [:] }
    }
    return states
  }

  static func write(_ states: [UUID: String], to exchange: URL) throws {
    let url = exchange.appendingPathComponent(fileName)
    guard !states.isEmpty else {
      guard unlink(url.path) == 0 || errno == ENOENT else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return
    }
    guard states.count <= maximumRequests, states.values.allSatisfy(valid) else {
      throw CocoaError(.coderInvalidValue)
    }
    let records = Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) })
    let data = try JSONEncoder().encode(records)
    guard data.count <= maximumFileBytes else { throw CocoaError(.coderInvalidValue) }
    try data.write(to: url, options: .atomic)
  }

  private static func valid(_ state: String) -> Bool {
    !state.isEmpty && state.utf8.count <= maximumStateBytes
      && !state.utf8.contains { $0 < 0x20 && $0 != 9 && $0 != 10 && $0 != 13 }
  }
}

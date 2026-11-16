import Foundation

@MainActor
final class LockScreenAcquireReplies {
  private var generation: UInt64 = 0
  private var replies: [(Error?) -> Void] = []

  var hasPending: Bool { !replies.isEmpty }

  func append(_ reply: @escaping (Error?) -> Void) {
    replies.append(reply)
  }

  func begin() -> UInt64 {
    generation &+= 1
    return generation
  }

  @discardableResult
  func complete(_ token: UInt64, error: Error?) -> Bool {
    guard token == generation else { return false }
    generation &+= 1
    let pending = replies
    replies.removeAll()
    pending.forEach { $0(error) }
    return true
  }

  func cancel() {
    complete(generation, error: CancellationError())
  }
}

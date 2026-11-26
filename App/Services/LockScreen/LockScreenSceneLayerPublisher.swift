import AppKit

@MainActor
final class LockScreenSceneLayerPublisher {
  static let request = Notification.Name("WallpaperMachine.requestSceneLayerState")
  static let ready = Notification.Name("WallpaperMachine.sceneLayerStateReady")

  private let exchange: URL
  private let center: NotificationCenter
  private let layer: (LockScreenSceneLayerRequest) -> CALayer?
  private let notifyChanged: () -> Void
  private var requests: Set<LockScreenSceneLayerRequest> = []
  private var pending: [UUID: ObjectIdentifier] = [:]
  private var states: [UUID: String] = [:]
  private var observer: NSObjectProtocol?

  init(exchange: URL, center: NotificationCenter = .default,
    layer: @escaping (LockScreenSceneLayerRequest) -> CALayer?,
    notifyChanged: @escaping () -> Void = {
      CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(LockScreenSceneLayerExchange.changedNotification as CFString), nil, nil, true)
    }
  ) {
    self.exchange = exchange
    self.center = center
    self.layer = layer
    self.notifyChanged = notifyChanged
  }

  func update(_ wanted: Set<LockScreenSceneLayerRequest>) {
    guard wanted != requests else { return }
    let tokens = Set(wanted.map(\.token))
    guard wanted.count <= LockScreenSceneLayerExchange.maximumRequests, tokens.count == wanted.count else {
      update([])
      return
    }
    let removed = requests.subtracting(wanted)
    let added = wanted.subtracting(requests)
    requests = wanted
    var changed = false
    for request in removed {
      pending.removeValue(forKey: request.token)
      if states.removeValue(forKey: request.token) != nil { changed = true }
    }
    if changed { publish() }
    if wanted.isEmpty {
      if let observer { center.removeObserver(observer) }
      observer = nil
      return
    }
    if observer == nil {
      observer = center.addObserver(forName: Self.ready, object: nil, queue: .main) { [weak self] note in
        MainActor.assumeIsolated { self?.receive(note) }
      }
    }
    for request in added {
      guard let target = layer(request) else { continue }
      pending[request.token] = ObjectIdentifier(target)
      center.post(name: Self.request, object: target, userInfo: ["context": request.token.uuidString])
    }
  }

  private func receive(_ note: Notification) {
    guard let context = note.userInfo?["context"] as? String, let token = UUID(uuidString: context),
      let target = note.object as? CALayer, pending[token] == ObjectIdentifier(target),
      let request = requests.first(where: { $0.token == token }), layer(request) === target
    else { return }
    pending.removeValue(forKey: token)
    guard let state = note.userInfo?["state"] as? String, !state.isEmpty,
      state.utf8.count <= LockScreenSceneLayerExchange.maximumStateBytes
    else { return }
    states[token] = state
    publish()
  }

  private func publish() {
    do {
      try LockScreenSceneLayerExchange.write(states, to: exchange)
      notifyChanged()
    } catch {
      AppLog.warn("Lock screen scene layer handoff failed: \(error.localizedDescription)")
    }
  }
}

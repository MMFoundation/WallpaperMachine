import AppKit
import ImageIO

/// Boundary behind which `DisplaySpanStillImageHost` presents one display's sliced slice of a
/// shared decoded `CGImage`, so tests can verify span grouping and image sharing without opening
/// real desktop windows.
@MainActor
protocol StillImageSpanSurface: AnyObject {
    var windowNumber: Int { get }
    var posterLayer: CALayer? { get }
    var isReadyForDisplay: Bool { get }
    func setScreenFrame(_ frame: NSRect)
    func apply(image: CGImage, slice: DisplaySpanGeometry.DisplaySlice)
    func posterImage() -> CGImage?
    func present()
    func stop()
}

/// One per-display desktop window showing its exact `contentsRect` slice of a single shared
/// `CGImage`, preserving macOS "Displays have separate Spaces" while decoding the image only once.
@objc(MWEStillImageSpanDesktopWindow)
final class StillImageSpanWindow: NSWindow, StillImageSpanSurface {
    let displayID: UInt32
    private let imageLayer = CALayer()
    private var currentImage: CGImage?
    private var currentSlice: DisplaySpanGeometry.DisplaySlice?
    private var stopped = false

    init(frame: NSRect, displayID: UInt32) {
        self.displayID = displayID
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        configureAsDesktopVideoWindow()
        let container = NativeVideoContainerView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.masksToBounds = true
        container.autoresizesSubviews = true
        imageLayer.contentsGravity = .resize
        imageLayer.backgroundColor = NSColor.black.cgColor
        imageLayer.frame = container.bounds
        container.layer?.addSublayer(imageLayer)
        container.onLayout = { [weak self] bounds, scale in
            self?.relayout(bounds: bounds, backingScale: scale)
        }
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var posterLayer: CALayer? { contentView?.layer }
    var isReadyForDisplay: Bool { !stopped && currentImage != nil && currentSlice != nil }
    var imageLayerForTest: CALayer { imageLayer }

    func setScreenFrame(_ frame: NSRect) {
        if self.frame != frame { setFrame(frame, display: false) }
        relayout(bounds: contentView?.bounds ?? NSRect(origin: .zero, size: frame.size), backingScale: backingScaleFactor)
    }

    func apply(image: CGImage, slice: DisplaySpanGeometry.DisplaySlice) {
        guard !stopped else { return }
        currentImage = image
        currentSlice = slice
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        imageLayer.contents = image
        imageLayer.contentsRect = slice.contentsRect
        imageLayer.contentsScale = backingScaleFactor > 0 ? backingScaleFactor : slice.backingScale
        if let bounds = contentView?.bounds {
            imageLayer.frame = bounds
        }
    }

    func posterImage() -> CGImage? {
        guard !stopped, let currentImage, let currentSlice else { return nil }
        return DisplaySpanGeometry.composePoster(from: currentImage, slice: currentSlice)
    }

    func present() {
        guard !stopped else { return }
        orderFrontRegardless()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        currentImage = nil
        currentSlice = nil
        imageLayer.contents = nil
        imageLayer.removeFromSuperlayer()
        orderOut(nil)
        close()
    }

    private func relayout(bounds: CGRect, backingScale: CGFloat) {
        guard !stopped else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        imageLayer.frame = bounds
        imageLayer.contentsScale = backingScale > 0 ? backingScale : 1
    }
}

/// Hosts multi-display spanned packaged still-image wallpapers across per-display `NSWindow`s
/// sharing one decoded `CGImage` per spanned wallpaper.
///
/// Phase 1 scope: packaged still-image wallpapers (`image-*` / `pixiv-*` verified by
/// `StillImagePageUpgrade`) assigned to 2+ displays while `DisplaySpanStore.isEnabled` is true.
/// Interactive Web wallpapers and Metal Scene wallpapers are left untouched by this host.
@MainActor
final class DisplaySpanStillImageHost {
    private struct CachedImage {
        let url: URL
        let stamp: StillImagePageUpgrade.Stamp?
        let image: CGImage
    }

    private struct CachedInspection {
        let projectPath: String
        let stamp: StillImagePageUpgrade.Stamp
        let imageURL: URL?
    }

    private struct FailedDecode: Equatable {
        let url: URL
        let stamp: StillImagePageUpgrade.Stamp?
    }

    static let inspectionCacheLimit = 64
    static let decodeFailedCacheLimit = 64

    private let fetch: @MainActor () async throws -> [BridgeWebWallpaper]
    private let screens: @MainActor () -> [(id: UInt32, frame: NSRect)]
    private let displayConfiguration: (@MainActor () -> DisplayConfiguration)?
    private let spanStore: DisplaySpanStore
    private let libraryURL: URL
    private let frameCenter: NotificationCenter
    private let switchHold: WallpaperSwitchHold?
    private let resolveImageURL: (@MainActor (BridgeWebWallpaper) -> URL?)?
    private let decodeImage: @Sendable (URL) -> CGImage?
    private let makeSurface: @MainActor (NSRect, UInt32) -> any StillImageSpanSurface

    private var surfaces: [UInt32: any StillImageSpanSurface] = [:]
    private var descriptors: [UInt32: BridgeWebWallpaper] = [:]
    private var states: [UInt32: HostWallpaperState] = [:]
    private var decodedImages: [String: CachedImage] = [:]
    private var inspectionCache: [String: CachedInspection] = [:]
    private var inspectionCacheOrder: [String] = []
    private var decodeFailedWallpapers: [String: FailedDecode] = [:]
    private var decodeFailedOrder: [String] = []
    private var spanObserver: NSObjectProtocol?
    private var posterObserver: NSObjectProtocol?
    private var reconcileInFlight = false
    private var reconcileRequested = false
    private var applyGeneration: UInt64 = 0
    private var stopped = false

    var onError: (@MainActor (String) -> Void)?
    var onSurfacesChanged: (@MainActor () -> Void)?
    var onStateChanged: (@MainActor (HostWallpaperState) -> Void)?
    /// Fired when the span preference toggles (for example, to trigger desktop poster refreshes).
    var onSpanPreferenceChanged: (@MainActor () -> Void)?
    /// Optional sequential `WebWallpaperHost` handoff invoked inside `reconcile()` so outgoing
    /// displays always close before incoming displays open, preventing window overlap, `.closed`
    /// state clobbering, and black screens when a still image fails to decode.
    var applyWebHost: (@MainActor ([BridgeWebWallpaper]) async -> Void)?

    init(
        fetch: @escaping @MainActor () async throws -> [BridgeWebWallpaper],
        screens: (@MainActor () -> [(id: UInt32, frame: NSRect)])? = nil,
        displayConfiguration: (@MainActor () -> DisplayConfiguration)? = nil,
        spanStore: DisplaySpanStore = .shared,
        libraryURL: URL = ClientPaths.libraryURL,
        frameCenter: NotificationCenter = .default,
        switchHold: WallpaperSwitchHold? = nil,
        resolveImageURL: (@MainActor (BridgeWebWallpaper) -> URL?)? = nil,
        decodeImage: (@Sendable (URL) -> CGImage?)? = nil,
        makeSurface: (@MainActor (NSRect, UInt32) -> any StillImageSpanSurface)? = nil
    ) {
        self.fetch = fetch
        self.screens = screens ?? { SystemDisplays.screens() }
        self.displayConfiguration = displayConfiguration
        self.spanStore = spanStore
        self.libraryURL = libraryURL
        self.frameCenter = frameCenter
        self.switchHold = switchHold
        self.resolveImageURL = resolveImageURL
        self.decodeImage = decodeImage ?? Self.loadOrientedImage(at:)
        self.makeSurface = makeSurface ?? { frame, displayID in
            StillImageSpanWindow(frame: frame, displayID: displayID)
        }
    }

    convenience init(
        bridge: WallpaperBridge,
        spanStore: DisplaySpanStore = .shared,
        switchHold: WallpaperSwitchHold? = nil
    ) {
        self.init(
            fetch: { try await bridge.webWallpapers() },
            spanStore: spanStore,
            switchHold: switchHold)
    }

    var activeDisplayIDs: Set<UInt32> { Set(surfaces.keys) }
    var isEmpty: Bool { surfaces.isEmpty }
    var decodedImageCountForTest: Int { decodedImages.count }
    var inspectionCacheCountForTest: Int { inspectionCache.count }
    var decodeFailedCountForTest: Int { decodeFailedWallpapers.count }

    /// True while this host actively owns or is loading a spanned still image on `displayID`, so
    /// `AppDelegate` can ignore a late `.closed` state from `WebWallpaperHost` during handoff.
    func hasActiveClaim(on displayID: UInt32) -> Bool {
        surfaces[displayID] != nil || states[displayID] != nil
    }

    func containsWallpaper(_ wallpaperID: String, on displayID: UInt32) -> Bool {
        descriptors[displayID]?.wallpaperId == wallpaperID
    }

    func wallpaperIsReady(_ wallpaperID: String, on displayID: UInt32) -> Bool {
        descriptors[displayID]?.wallpaperId == wallpaperID && surfaces[displayID]?.isReadyForDisplay == true
    }

    var windowWallpapers: [Int: String] {
        var result: [Int: String] = [:]
        for (displayID, surface) in surfaces {
            if let id = descriptors[displayID]?.wallpaperId {
                result[surface.windowNumber] = id
            }
        }
        return result
    }

    /// Pure grouping rule: returns the display IDs that form 2+ display groups sharing one packaged
    /// still image while `spanEnabled` is true.
    static func spannedDisplayIDs(
        in wallpapers: [BridgeWebWallpaper],
        spanEnabled: Bool,
        screens: [(id: UInt32, frame: NSRect)],
        isPackagedStill: (BridgeWebWallpaper) -> Bool
    ) -> Set<UInt32> {
        guard spanEnabled, screens.count >= 2 else { return [] }
        let screenIDs = Set(screens.map(\.id))
        var byWallpaper: [String: [BridgeWebWallpaper]] = [:]
        for wallpaper in wallpapers where screenIDs.contains(wallpaper.displayId) {
            byWallpaper[wallpaper.wallpaperId, default: []].append(wallpaper)
        }
        var claimed: Set<UInt32> = []
        for group in byWallpaper.values where group.count >= 2 {
            guard let representative = group.first, isPackagedStill(representative) else { continue }
            for member in group { claimed.insert(member.displayId) }
        }
        return claimed
    }

    /// Filters out displays claimed by this host so `WebWallpaperHost` does not open redundant
    /// `WKWebView` windows underneath the spanned still-image layers. Wallpapers whose still image
    /// previously failed to decode for their current URL/stamp are never excluded so
    /// `WebWallpaperHost` renders them as a graceful fallback.
    func filterForWebHost(_ wallpapers: [BridgeWebWallpaper]) -> [BridgeWebWallpaper] {
        guard spanStore.isEnabled else { return wallpapers }
        let claimed = Self.spannedDisplayIDs(
            in: wallpapers,
            spanEnabled: true,
            screens: screens(),
            isPackagedStill: { [weak self] wallpaper in
                self?.canClaimForSpan(wallpaper) == true
            })
        guard !claimed.isEmpty else { return wallpapers }
        return wallpapers.filter { !claimed.contains($0.displayId) }
    }

    /// Synchronously closes any still-span surfaces and host states not claimed by `wallpapers`
    /// so outgoing `.closed` transitions always complete before `WebWallpaperHost` opens replacements.
    func closeUnclaimed(for wallpapers: [BridgeWebWallpaper]) {
        let claimedIDs = Self.spannedDisplayIDs(
            in: wallpapers,
            spanEnabled: spanStore.isEnabled,
            screens: screens(),
            isPackagedStill: { [weak self] wallpaper in
                self?.canClaimForSpan(wallpaper) == true
            })
        for (displayID, surface) in surfaces where !claimedIDs.contains(displayID) {
            close(displayID: displayID, surface: surface)
        }
        for (displayID, var state) in states where !claimedIDs.contains(displayID) {
            state.phase = .closed
            onStateChanged?(state)
            states.removeValue(forKey: displayID)
        }
    }

    func start() {
        guard posterObserver == nil else { return }
        posterObserver = frameCenter.addObserver(
            forName: DesktopPosterNotification.request,
            object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.answerPosterRequest(notification) }
        }
        spanObserver = NotificationCenter.default.addObserver(
            forName: DisplaySpanStore.didChangeNotification,
            object: spanStore, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcile()
                self?.onSpanPreferenceChanged?()
            }
        }
        stopped = false
    }

    func reconcile() {
        guard !stopped else { return }
        guard !reconcileInFlight else {
            reconcileRequested = true
            return
        }
        reconcileInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.reconcileInFlight = false
                if self.reconcileRequested {
                    self.reconcileRequested = false
                    self.reconcile()
                }
            }
            do {
                let wallpapers = try await self.fetch()
                guard !self.stopped else { return }
                if let applyWebHost = self.applyWebHost {
                    // 1. Release displays leaving still-span before WebWallpaperHost opens them.
                    self.closeUnclaimed(for: wallpapers)
                    // 2. Run WebWallpaperHost sequentially so displays moving into still-span close
                    //    their web views and emit `.closed` before still-span opens them.
                    await applyWebHost(self.filterForWebHost(wallpapers))
                    guard !self.stopped, !self.reconcileRequested else { return }
                    // 3. Apply claimed still-span displays; if any decode fails, hand those displays
                    //    immediately back to WebWallpaperHost instead of leaving a black screen.
                    let fellBack = await self.applyInternal(wallpapers, fallbackToWebHost: true)
                    guard !self.stopped, !self.reconcileRequested else { return }
                    if fellBack {
                        await applyWebHost(self.filterForWebHost(wallpapers))
                    }
                } else {
                    _ = await self.applyInternal(wallpapers, fallbackToWebHost: false)
                }
            } catch {
                AppLog.error("still image span wallpapers could not be read: \(error.localizedDescription)")
                self.onError?(error.localizedDescription)
            }
        }
    }

    func apply(_ wallpapers: [BridgeWebWallpaper]) async {
        _ = await applyInternal(wallpapers, fallbackToWebHost: applyWebHost != nil)
    }

    @discardableResult
    private func applyInternal(_ wallpapers: [BridgeWebWallpaper], fallbackToWebHost: Bool) async -> Bool {
        applyGeneration &+= 1
        let generation = applyGeneration
        let currentScreens = screens()
        let claimedIDs = Self.spannedDisplayIDs(
            in: wallpapers,
            spanEnabled: spanStore.isEnabled,
            screens: currentScreens,
            isPackagedStill: { [weak self] wallpaper in
                self?.canClaimForSpan(wallpaper) == true
            })

        var wanted: [UInt32: BridgeWebWallpaper] = [:]
        for wallpaper in wallpapers where claimedIDs.contains(wallpaper.displayId) {
            wanted[wallpaper.displayId] = wallpaper
        }

        // Close displays no longer spanned by this host.
        for (displayID, surface) in surfaces where wanted[displayID] == nil {
            close(displayID: displayID, surface: surface)
        }
        for (displayID, var state) in states where wanted[displayID] == nil {
            state.phase = .closed
            onStateChanged?(state)
            states.removeValue(forKey: displayID)
        }

        // Group claimed displays by wallpaper ID so each wallpaper is decoded at most once.
        var groups: [String: [BridgeWebWallpaper]] = [:]
        for wallpaper in wanted.values {
            groups[wallpaper.wallpaperId, default: []].append(wallpaper)
        }
        let activeWallpaperIDs = Set(groups.keys)
        decodedImages = decodedImages.filter { activeWallpaperIDs.contains($0.key) }

        let config = currentDisplayConfiguration(for: currentScreens)
        var fellBackToWeb = false

        for (wallpaperID, members) in groups.sorted(by: { $0.key < $1.key }) {
            guard !stopped, generation == applyGeneration else { return false }
            let sortedMembers = members.sorted { $0.displayId < $1.displayId }
            guard sortedMembers.count >= 2,
                  let representative = sortedMembers.first,
                  let imageURL = resolvedImageURL(for: representative)
            else {
                for member in sortedMembers {
                    if let surface = surfaces[member.displayId] {
                        close(displayID: member.displayId, surface: surface)
                    }
                }
                continue
            }

            let stamp = imageStamp(for: representative)

            let image: CGImage?
            if let cached = decodedImages[wallpaperID], cached.url == imageURL, cached.stamp == stamp {
                image = cached.image
            } else {
                for member in sortedMembers where surfaces[member.displayId] == nil {
                    recordState(member, phase: .loading)
                }
                let decode = decodeImage
                let loaded = await Task.detached(priority: .userInitiated) {
                    decode(imageURL)
                }.value
                guard !stopped, generation == applyGeneration else { return false }
                if let loaded {
                    decodedImages[wallpaperID] = CachedImage(url: imageURL, stamp: stamp, image: loaded)
                    decodeFailedWallpapers.removeValue(forKey: wallpaperID)
                    decodeFailedOrder.removeAll { $0 == wallpaperID }
                    image = loaded
                } else {
                    image = nil
                }
            }

            guard let image else {
                recordDecodeFailure(wallpaperID: wallpaperID, url: imageURL, stamp: stamp)
                let failureMessage = String(localized: "The still image could not be decoded for multi-display span.")
                AppLog.warn("still image span \(wallpaperID): \(failureMessage)")
                fellBackToWeb = true
                for member in sortedMembers {
                    if let surface = surfaces[member.displayId] {
                        close(displayID: member.displayId, surface: surface)
                    }
                    if fallbackToWebHost {
                        if var state = states.removeValue(forKey: member.displayId) {
                            state.phase = .closed
                            onStateChanged?(state)
                        }
                    } else {
                        recordState(member, phase: .failed, message: failureMessage)
                    }
                }
                continue
            }

            let mediaSize = CGSize(width: image.width, height: image.height)
            let memberIDs = Set(sortedMembers.map(\.displayId))
            guard let geometry = DisplaySpanGeometry.compute(
                configuration: config, mediaSize: mediaSize, includedDisplayIDs: memberIDs)
            else { continue }

            for member in sortedMembers {
                guard let slice = geometry.slice(for: member.displayId),
                      let frame = currentScreens.first(where: { $0.id == member.displayId })?.frame
                else { continue }

                let surface: any StillImageSpanSurface
                let isNew: Bool
                let wallpaperChanged = descriptors[member.displayId]?.wallpaperId != member.wallpaperId
                if let existing = surfaces[member.displayId] {
                    surface = existing
                    isNew = false
                    surface.setScreenFrame(frame)
                } else {
                    surface = makeSurface(frame, member.displayId)
                    surfaces[member.displayId] = surface
                    isNew = true
                }
                descriptors[member.displayId] = member
                surface.apply(image: image, slice: slice)
                if isNew {
                    if let layer = surface.posterLayer {
                        _ = switchHold?.adopt(into: layer, displayID: member.displayId)
                    }
                    surface.present()
                    switchHold?.contentReady(displayID: member.displayId)
                } else if wallpaperChanged {
                    if let layer = surface.posterLayer {
                        _ = switchHold?.adopt(into: layer, displayID: member.displayId)
                    }
                    switchHold?.contentReady(displayID: member.displayId)
                }
                recordState(member, phase: .ready)
            }
        }

        guard generation == applyGeneration else { return false }
        onSurfacesChanged?()
        return fellBackToWeb
    }

    func shutdown() {
        stopped = true
        if let posterObserver {
            frameCenter.removeObserver(posterObserver)
            self.posterObserver = nil
        }
        if let spanObserver {
            NotificationCenter.default.removeObserver(spanObserver)
            self.spanObserver = nil
        }
        for (displayID, surface) in surfaces {
            close(displayID: displayID, surface: surface)
        }
        surfaces.removeAll()
        descriptors.removeAll()
        states.removeAll()
        decodedImages.removeAll()
        inspectionCache.removeAll()
        inspectionCacheOrder.removeAll()
        decodeFailedWallpapers.removeAll()
        decodeFailedOrder.removeAll()
    }

    private func close(displayID: UInt32, surface: any StillImageSpanSurface) {
        let layer = surface.posterLayer
        if let descriptor = descriptors[displayID] {
            recordState(descriptor, phase: .closed)
        }
        states.removeValue(forKey: displayID)
        surface.stop()
        surfaces.removeValue(forKey: displayID)
        descriptors.removeValue(forKey: displayID)
        switchHold?.windowClosed(layer, displayID: displayID)
    }

    private func recordState(
        _ wallpaper: BridgeWebWallpaper, phase: HostWallpaperState.Phase, message: String? = nil
    ) {
        let state = HostWallpaperState(
            kind: .web, displayID: wallpaper.displayId, wallpaperID: wallpaper.wallpaperId,
            startupRevision: wallpaper.startupRevision, phase: phase, message: message)
        guard states[wallpaper.displayId] != state else { return }
        states[wallpaper.displayId] = state
        onStateChanged?(state)
    }

    private func imageStamp(for wallpaper: BridgeWebWallpaper) -> StillImagePageUpgrade.Stamp? {
        resolveImageURL == nil
            ? StillImagePageUpgrade.stamp(project: URL(fileURLWithPath: wallpaper.projectPath))
            : nil
    }

    private func canClaimForSpan(_ wallpaper: BridgeWebWallpaper) -> Bool {
        guard let url = resolvedImageURL(for: wallpaper) else { return false }
        let stamp = imageStamp(for: wallpaper)
        if let failed = decodeFailedWallpapers[wallpaper.wallpaperId],
           failed.url == url, failed.stamp == stamp
        {
            return false
        }
        return true
    }

    private func recordDecodeFailure(
        wallpaperID: String, url: URL, stamp: StillImagePageUpgrade.Stamp?
    ) {
        decodeFailedWallpapers[wallpaperID] = FailedDecode(url: url, stamp: stamp)
        decodeFailedOrder.removeAll { $0 == wallpaperID }
        decodeFailedOrder.append(wallpaperID)
        while decodeFailedOrder.count > Self.decodeFailedCacheLimit {
            decodeFailedWallpapers.removeValue(forKey: decodeFailedOrder.removeFirst())
        }
    }

    private func resolvedImageURL(for wallpaper: BridgeWebWallpaper) -> URL? {
        if let resolveImageURL {
            return resolveImageURL(wallpaper)
        }
        guard wallpaper.wallpaperId.hasPrefix("image-") || wallpaper.wallpaperId.hasPrefix("pixiv-") else {
            return nil
        }
        let projectURL = URL(fileURLWithPath: wallpaper.projectPath)
        let stamp = StillImagePageUpgrade.stamp(project: projectURL)
        if let cached = inspectionCache[wallpaper.wallpaperId],
           cached.projectPath == wallpaper.projectPath,
           cached.stamp == stamp
        {
            return cached.imageURL
        }
        let result = try? StillImagePageUpgrade.inspect(
            wallpaperID: wallpaper.wallpaperId, project: projectURL, library: libraryURL)
        let url = result.map { projectURL.appendingPathComponent($0.imageFile) }
        inspectionCache[wallpaper.wallpaperId] = CachedInspection(
            projectPath: wallpaper.projectPath, stamp: stamp, imageURL: url)
        inspectionCacheOrder.removeAll { $0 == wallpaper.wallpaperId }
        inspectionCacheOrder.append(wallpaper.wallpaperId)
        while inspectionCacheOrder.count > Self.inspectionCacheLimit {
            inspectionCache.removeValue(forKey: inspectionCacheOrder.removeFirst())
        }
        return url
    }

    private func currentDisplayConfiguration(for currentScreens: [(id: UInt32, frame: NSRect)]) -> DisplayConfiguration {
        if let displayConfiguration { return displayConfiguration() }
        let systemByID = Dictionary(
            uniqueKeysWithValues: DisplayConfiguration.current().displays.map { ($0.id, $0) })
        return DisplayConfiguration(displays: currentScreens.map { screen in
            let system = systemByID[screen.id]
            return DisplayConfiguration.Display(
                id: screen.id,
                frame: screen.frame,
                scale: system?.scale ?? 1,
                refreshRate: system?.refreshRate ?? 60)
        })
    }

    private func answerPosterRequest(_ notification: Notification) {
        guard !stopped, let layer = notification.object as? CALayer,
              let surface = surfaces.values.first(where: { $0.posterLayer === layer }),
              let image = surface.posterImage(),
              let frame = DesktopPosterFrame.rgba(image)
        else { return }
        frame.publish(for: layer, to: frameCenter, context: DesktopPosterNotification.context(in: notification.userInfo))
    }

    /// Decodes an image file once into a single `CGImage`, applying any EXIF orientation transform
    /// so rotated photographs span upright across displays.
    nonisolated static func loadOrientedImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (2...8).contains(orientation),
           let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           max(width, height) > 0
        {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

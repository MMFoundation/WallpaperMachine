import Foundation

@MainActor
extension BridgeStore {
    func displayTransferSnapshot() -> WallpaperDisplayTransfer.Snapshot {
        .init(displays: settingsSnapshot.displays.map { display in
            let assignment = monitorInformationSnapshot.rows.first { $0.displayId == display.displayId && $0.mirrorTargetDisplayId == nil }
            return .init(id: display.displayId, title: display.title.isEmpty ? display.displayId : display.title,
                         eligible: display.isIndependent,
                         wallpaperID: assignment.flatMap { $0.wallpaperId.isEmpty ? nil : $0.wallpaperId })
        }, wallpapers: Set(librarySnapshot.wallpapers.filter(\.supported).map(\.id)), reliable: !activationNeedsRefresh,
           held: Set(heldWallpaperIDs))
    }

    /// One wallpaper on every enabled independent display, or on none of them: a failure puts
    /// each display back as it was, and says so when one cannot be put back. A mirror follows
    /// its source, so it is left out.
    func activateWallpaperEverywhereAsync(id: String) async throws {
        try await applyDisplayTransferAsync(.everywhere(wallpaperID: id))
    }

    func applyDisplayTransferAsync(_ request: WallpaperDisplayTransfer.Request) async throws {
        // A layout is one user command. Later individual choices wait behind the whole
        // operation, including rollback; no screen receives half of a coalesced swap.
        // It has no slot of its own, so it counts as the user's choice for each display it
        // names as it is asked for, and work waiting on one of them (a Download and apply)
        // stands down.
        commands.noteUserChoice(in: request.displayIDs(in: displayTransferSnapshot()).map { Self.activationSlot(displayId: $0) })
        try await commands.run {
            let before = displayTransferSnapshot()
            var successful: [WallpaperDisplayAssignment] = []
            var touched = Set<String>()
            defer {
                let after = displayTransferSnapshot()
                if after.reliable {
                    for screen in after.displays where screen.eligible && (touched.contains(screen.id) || successful.contains { $0.displayID == screen.id }) {
                        let previous = before.displays.first { $0.id == screen.id }?.wallpaperID
                        if let current = screen.wallpaperID, current != previous {
                            history.recordSwitch(from: previous, to: current, on: screen.id)
                            onUserWallpaperChoice?(current, screen.id)
                            if !successful.isEmpty { supportPrompt?.recordSuccessfulActivation(wallpaperID: current) }
                        } else if successful.contains(where: { $0.displayID == screen.id }), let current = screen.wallpaperID {
                            onUserWallpaperChoice?(current, screen.id)
                        }
                    }
                }
            }
            successful = try await WallpaperDisplayTransfer.execute(request, snapshot: { self.displayTransferSnapshot() },
                prepare: { ids in
                    for id in ids.sorted() {
                        let options = try await self.wallpaperOptionsSnapshotAsync(wallpaperId: id)
                        guard !options.dirty, !self.editorState.hasPendingEdits(wallpaperID: id) else {
                            throw WallpaperDisplayLayoutError.pendingEdits
                        }
                    }
                }, apply: { id, display in
                    touched.insert(display)
                    try await self.activateWallpaperAsync(id: id, displayId: display, origin: .layout, recordsHistory: false,
                                                          releasesHold: request.releasesHold)
                }, clear: { id, display in
                    try await self.ejectWallpaperFromDisplayAsync(displayId: display, wallpaperId: id)
                })
        }
    }
}

/// Applies the matching `autoApplyOnConnect` display layout once `DisplayRefreshCoalescer`
/// settles on a changed connected display topology.
///
/// Tracks the last observed eligible topology so resolution/refresh changes, repeated screen
/// notifications, or layouts that are already showing never re-trigger in a loop.
@MainActor
final class DisplayTopologyLayoutAutoApplier {
    private let snapshot: @MainActor () -> WallpaperDisplayTransfer.Snapshot
    private let matchingLayout: @MainActor ([String]) -> WallpaperDisplayLayout?
    private let applyLayout: @MainActor (WallpaperDisplayLayout) async throws -> Void
    private var lastTopology: [String]?
    private var isApplying = false
    private var needsRecheck = false

    init(
        snapshot: @escaping @MainActor () -> WallpaperDisplayTransfer.Snapshot,
        matchingLayout: @escaping @MainActor ([String]) -> WallpaperDisplayLayout?,
        applyLayout: @escaping @MainActor (WallpaperDisplayLayout) async throws -> Void
    ) {
        self.snapshot = snapshot
        self.matchingLayout = matchingLayout
        self.applyLayout = applyLayout
    }

    /// Captures the initial connected display topology after launch so startup does not overwrite
    /// current wallpapers before an actual connect/disconnect change occurs.
    func seedTopology() {
        let current = snapshot()
        guard current.reliable else { return }
        lastTopology = Self.eligibleTopology(in: current)
    }

    /// Evaluates the settled display snapshot after a system screen-change refresh.
    /// Returns the applied layout ID when a layout was applied, or nil when skipped.
    @discardableResult
    func handleTopologySettled() async -> String? {
        if isApplying {
            needsRecheck = true
            return nil
        }
        isApplying = true
        defer { isApplying = false }

        var lastAppliedID: String?
        while true {
            needsRecheck = false
            let current = snapshot()
            guard current.reliable else { break }
            let topology = Self.eligibleTopology(in: current)
            guard !topology.isEmpty, topology != lastTopology else { break }
            lastTopology = topology

            guard let layout = matchingLayout(topology) else {
                if !needsRecheck { break }
                continue
            }
            if Self.isSatisfied(layout, in: current) {
                AppLog.debug("display layout auto-apply: '\(layout.name)' is already applied for topology \(topology)")
                if !needsRecheck { break }
                continue
            }
            do {
                try WallpaperDisplayTransfer.validate(layout.assignments, in: current)
            } catch {
                AppLog.info("display layout auto-apply: skipping '\(layout.name)': \(error.localizedDescription)")
                if !needsRecheck { break }
                continue
            }
            do {
                AppLog.info("display layout auto-apply: applying '\(layout.name)' for topology \(topology)")
                try await applyLayout(layout)
                lastAppliedID = layout.id
            } catch {
                AppLog.warn("display layout auto-apply: '\(layout.name)' failed: \(error.localizedDescription)")
            }
            if !needsRecheck { break }
        }
        return lastAppliedID
    }

    nonisolated static func eligibleTopology(in snapshot: WallpaperDisplayTransfer.Snapshot) -> [String] {
        WallpaperDisplayLayout.normalizedDisplayTopology(for: snapshot.displays.filter(\.eligible).map(\.id))
    }

    nonisolated static func isSatisfied(
        _ layout: WallpaperDisplayLayout,
        in snapshot: WallpaperDisplayTransfer.Snapshot
    ) -> Bool {
        guard !layout.assignments.isEmpty else { return false }
        return layout.assignments.allSatisfy { assignment in
            snapshot.displays.first { $0.id == assignment.displayID && $0.eligible }?.wallpaperID == assignment.wallpaperID
        }
    }
}

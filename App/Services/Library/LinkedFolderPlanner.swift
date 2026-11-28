import Foundation

/// Works out what one look at a linked folder changes in the library, from the folder as it is now
/// and what the link recorded. Pure: no disk, no clock and no library, so every rule is testable.
enum LinkedFolderPlanner {
    struct Plan: Equatable, Sendable {
        /// Files to import now: new or changed, and the same size and date as at the last check.
        var imports: [LinkedFolderScan.Item] = []
        /// Library items to remove now: wallpapers of files that left (`leaving`) and items no file
        /// stands for any more. The coordinator asks again just before removing.
        var removals: [String] = []
        /// Library items whose files left the folder in a number too large to remove without asking.
        var held: [String] = []
        /// The record after this look, before any import or removal ran.
        var record: LinkedFolderRecord
        /// A file is new or still changing: look again shortly.
        var needsRecheck = false
        var isUnavailable = false
    }

    /// More removals than this at once are held for confirmation.
    static let massRemovalCount = 20
    /// Removing more than this share of the link's wallpapers at once is held for confirmation.
    static let massRemovalShare = 0.25

    static func plan(
        record: LinkedFolderRecord, scan: LinkedFolderScan, mirrorsDeletions: Bool, installed: Set<String>
    ) -> Plan {
        guard case .contents(let contents) = scan else {
            // A folder that cannot be read says nothing about its files: wait for it.
            return Plan(record: record, isUnavailable: true)
        }
        var plan = Plan(record: record)
        var next = record
        let items = Dictionary(contents.items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        // The library may be on a volume that ignores case, where `Rain.mp4` lands on `rain.mp4`.
        let installedKeys = Set(installed.map { $0.lowercased() })

        var kept: [LinkedFolderRecord.Entry] = []
        var gone: [LinkedFolderRecord.Entry] = []
        // A leaving item that is no longer installed has been removed: its entry is done.
        for entry in record.entries where !(entry.state == .leaving && !installed.contains(entry.libraryID)) {
            if contents.present.contains(entry.path) {
                kept.append(entry)
            } else {
                gone.append(entry)
            }
        }

        // A file that left under one name and is here under another is the same file renamed.
        var known = Set(kept.map(\.path))
        var unmatched = contents.items.filter { !known.contains($0.path) }
        var departed: [LinkedFolderRecord.Entry] = []
        for entry in gone {
            if let fileID = entry.fileID, let index = unmatched.firstIndex(where: { $0.fileID == fileID }) {
                var renamed = entry
                renamed.path = unmatched.remove(at: index).path
                kept.append(renamed)
                known.insert(renamed.path)
            } else {
                departed.append(entry)
            }
        }

        var entries: [LinkedFolderRecord.Entry] = []
        var claimed = Set(kept.map { $0.libraryID.lowercased() })
        for var entry in kept {
            guard let item = items[entry.path] else {
                // Here but unreadable, or evicted by iCloud Drive: still the folder's, never removed.
                if entry.state == .leaving { entry.state = .present }
                entries.append(entry)
                continue
            }
            // Back in the folder: a removal still due is called off.
            entry.state = .present
            entry.removalConfirmed = nil
            entry.fileID = item.fileID ?? entry.fileID
            if item.stamp == entry.stamp {
                next.pending[item.path] = nil
                next.failed[item.path] = nil
            } else if !entry.owned {
                // Never copied over an item this link did not import.
                entry.stamp = item.stamp
            } else if item.libraryID.lowercased() != entry.libraryID.lowercased(),
                      installedKeys.contains(item.libraryID.lowercased()) || claimed.contains(item.libraryID.lowercased()) {
                // Renamed and changed onto an id another wallpaper has: never imported over it.
                next.pending[item.path] = nil
            } else if settled(item, in: &next, plan: &plan) {
                plan.imports.append(item)
            }
            entries.append(entry)
        }

        for item in unmatched {
            let key = item.libraryID.lowercased()
            if let index = next.pendingRemovals.firstIndex(where: { $0.lowercased() == key }),
               installed.contains(next.pendingRemovals[index]) {
                // Back before its wallpaper was removed: it stays.
                let id = next.pendingRemovals.remove(at: index)
                entries.append(.init(path: item.path, libraryID: id, stamp: item.stamp, fileID: item.fileID, owned: true))
                claimed.insert(key)
            } else if installedKeys.contains(key) || claimed.contains(key) {
                // Somebody else's item of the same id: recorded, never replaced or removed.
                entries.append(.init(path: item.path, libraryID: item.libraryID, stamp: item.stamp,
                                     fileID: item.fileID, owned: false))
                claimed.insert(key)
                next.pending[item.path] = nil
            } else if settled(item, in: &next, plan: &plan) {
                plan.imports.append(item)
            }
        }

        // Removals not yet confirmed are weighed together, including those already decided but
        // still waiting (while no panel was open): many single departures are still many.
        let unconfirmed: (LinkedFolderRecord.Entry) -> Bool = {
            $0.owned && ($0.state == .present || ($0.state == .leaving && $0.removalConfirmed != true))
        }
        var candidates: [LinkedFolderRecord.Entry] = []
        for var entry in departed where entry.owned {
            if mirrorsDeletions && unconfirmed(entry) {
                candidates.append(entry)
            } else {
                // Kept, or confirmed and leaving (and kept after all if Mirror deletions went off).
                if entry.state == .present || !mirrorsDeletions { entry.state = .missing }
                entries.append(entry)
            }
        }
        if isMassRemoval(candidates.count, of: record.entries.filter(unconfirmed).count) {
            plan.held = candidates.map(\.libraryID)
            entries += candidates.map { var held = $0; held.state = .present; return held }
        } else {
            entries += candidates.map { var leaving = $0; leaving.state = .leaving; return leaving }
        }

        let present = Set(contents.items.map(\.path))
        next.pending = next.pending.filter { present.contains($0.key) }
        next.failed = next.failed.filter { present.contains($0.key) }
        let referenced = Set(entries.filter { $0.state != .leaving }.map(\.libraryID))
        var seen = Set<String>()
        next.pendingRemovals = mirrorsDeletions ? next.pendingRemovals.filter {
            installed.contains($0) && !referenced.contains($0) && seen.insert($0).inserted
        } : []
        next.entries = entries.sorted { $0.path < $1.path }
        plan.removals = dueRemovals(next, installed: installed)
        plan.record = next
        return plan
    }

    /// The library items `record` has decided to remove and that are still installed: the
    /// wallpapers of files that left, and items no file stands for any more.
    static func dueRemovals(_ record: LinkedFolderRecord, installed: Set<String>) -> [String] {
        let keep = Set(record.entries.filter { $0.state != .leaving }.map(\.libraryID))
        var seen = Set<String>()
        return (record.entries.filter { $0.state == .leaving && $0.owned }.map(\.libraryID) + record.pendingRemovals)
            .filter { installed.contains($0) && !keep.contains($0) && seen.insert($0).inserted }
    }

    /// Whether removing `count` of a link's `total` wallpapers at once needs the user's go-ahead.
    /// A single removal never does, however small the folder.
    static func isMassRemoval(_ count: Int, of total: Int) -> Bool {
        count > 1 && (count > massRemovalCount || Double(count) > Double(total) * massRemovalShare)
    }

    /// Records what an import of `item` did. `importedID` is the id it has in the library now, or
    /// nil when it failed. The link owns the item only when it was not installed before the import
    /// (`installedBefore`) or was already this file's: an import that landed on somebody else's
    /// wallpaper never makes it the link's to remove. A renamed file that was changed comes back
    /// under its new name's id; the item under the old one is then due for removal when Mirror
    /// deletions is on.
    static func recordImport(
        _ item: LinkedFolderScan.Item, importedID: String?, mirrorsDeletions: Bool,
        installedBefore: Set<String>, in record: inout LinkedFolderRecord
    ) {
        record.pending[item.path] = nil
        guard let id = importedID else {
            record.failed[item.path] = item.stamp
            return
        }
        record.failed[item.path] = nil
        let index = record.entries.firstIndex(where: { $0.path == item.path })
        let previous = index.map { record.entries[$0] }
        let wasThisFiles = previous.map { $0.owned && $0.libraryID.lowercased() == id.lowercased() } ?? false
        let owned = wasThisFiles || !installedBefore.contains { $0.lowercased() == id.lowercased() }
        let entry = LinkedFolderRecord.Entry(path: item.path, libraryID: id, stamp: item.stamp,
                                             fileID: item.fileID, owned: owned)
        if let index, let previous {
            record.entries[index] = entry
            if previous.owned, previous.libraryID != id, mirrorsDeletions,
               !record.entries.contains(where: { $0.libraryID == previous.libraryID }) {
                record.pendingRemovals.append(previous.libraryID)
            }
        } else {
            record.entries.append(entry)
            record.entries.sort { $0.path < $1.path }
        }
        if owned { record.pendingRemovals.removeAll { $0 == id } }
    }

    /// What an import report says became of `item`: the id it has in the library (identical
    /// content already there counts), a failure, or not reached by a cancelled import.
    static func outcome(of item: LinkedFolderScan.Item, in report: WallpaperImportService.Report) -> Outcome {
        let id = report.recognizedWorkshopIDs[item.path] ?? item.libraryID
        if report.importedIDs.contains(id) || report.skipped.contains(item.path) { return .imported(id) }
        if report.failures.contains(where: { $0.hasPrefix(item.path + ": ") }) { return .failed }
        return report.cancelled ? .notReached : .failed
    }

    enum Outcome: Equatable, Sendable {
        case imported(String)
        case failed
        case notReached
    }

    /// The user confirmed held removals: those files' wallpapers are due to be removed.
    static func confirmHeld(_ ids: [String], in record: inout LinkedFolderRecord) {
        let confirmed = Set(ids)
        for index in record.entries.indices
        where confirmed.contains(record.entries[index].libraryID) && record.entries[index].owned
            && record.entries[index].state == .present {
            record.entries[index].state = .leaving
            record.entries[index].removalConfirmed = true
        }
    }

    /// The user kept held items: they stay in the library and are never removed for this folder.
    static func keepHeld(_ ids: [String], in record: inout LinkedFolderRecord) {
        let keep = Set(ids)
        for index in record.entries.indices
        where keep.contains(record.entries[index].libraryID) && record.entries[index].state == .present {
            record.entries[index].state = .missing
        }
    }

    /// Mirror deletions went off: nothing still due is removed; those wallpapers are kept.
    static func stopMirroring(_ record: inout LinkedFolderRecord) {
        for index in record.entries.indices where record.entries[index].state == .leaving {
            record.entries[index].state = .missing
        }
        record.pendingRemovals = []
    }

    /// `ids` left the library: their leaving entries and queued removals are done.
    static func recordRemoved(_ ids: Set<String>, in record: inout LinkedFolderRecord) {
        record.entries.removeAll { $0.state == .leaving && ids.contains($0.libraryID) }
        record.pendingRemovals.removeAll { ids.contains($0) }
    }

    /// True when `item` looks the same as at the last check, so it is not being written any more.
    /// Otherwise remembers how it looks now and asks for another check. A file whose import
    /// failed is not tried again until it changes.
    private static func settled(_ item: LinkedFolderScan.Item, in record: inout LinkedFolderRecord, plan: inout Plan) -> Bool {
        if record.failed[item.path] == item.stamp { return false }
        record.failed[item.path] = nil
        if record.pending[item.path] == item.stamp { return true }
        record.pending[item.path] = item.stamp
        plan.needsRecheck = true
        return false
    }
}

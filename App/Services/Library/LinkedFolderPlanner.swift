import Foundation

/// Works out what one look at a linked folder changes in the library, from the folder as it is now
/// and what the link recorded. Pure: no disk, no clock and no library, so every rule is testable.
enum LinkedFolderPlanner {
    struct Plan: Equatable, Sendable {
        /// Files to import now: new or changed, and the same size and date as at the last check.
        var imports: [LinkedFolderScan.Item] = []
        /// Library items to remove now: removals already decided, never more than were decided.
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

        var kept: [LinkedFolderRecord.Entry] = []
        var gone: [LinkedFolderRecord.Entry] = []
        for entry in record.entries {
            if items[entry.path] != nil || contents.evicted.contains(entry.path) {
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
        for var entry in kept {
            guard let item = items[entry.path] else {
                entries.append(entry)  // evicted by iCloud Drive: still the folder's
                continue
            }
            entry.state = .present
            entry.fileID = item.fileID ?? entry.fileID
            if item.stamp == entry.stamp {
                next.pending[item.path] = nil
                next.failed[item.path] = nil
            } else if !entry.owned {
                // Never copied over an item this link did not import.
                entry.stamp = item.stamp
            } else if settled(item, in: &next, plan: &plan) {
                plan.imports.append(item)
            }
            entries.append(entry)
        }

        var claimed = Set(entries.map(\.libraryID))
        for item in unmatched {
            if let index = next.pendingRemovals.firstIndex(of: item.libraryID), installed.contains(item.libraryID) {
                // Back before its wallpaper was removed: it stays.
                next.pendingRemovals.remove(at: index)
                entries.append(.init(path: item.path, libraryID: item.libraryID, stamp: item.stamp,
                                     fileID: item.fileID, owned: true))
                claimed.insert(item.libraryID)
            } else if installed.contains(item.libraryID) || claimed.contains(item.libraryID) {
                // Somebody else's item of the same id: recorded, never replaced or removed.
                entries.append(.init(path: item.path, libraryID: item.libraryID, stamp: item.stamp,
                                     fileID: item.fileID, owned: false))
                claimed.insert(item.libraryID)
                next.pending[item.path] = nil
            } else if settled(item, in: &next, plan: &plan) {
                plan.imports.append(item)
            }
        }

        var candidates: [LinkedFolderRecord.Entry] = []
        for var entry in departed {
            if !entry.owned { continue }
            if entry.state == .missing || !mirrorsDeletions {
                entry.state = .missing
                entries.append(entry)
            } else {
                candidates.append(entry)
            }
        }
        if isMassRemoval(candidates.count, of: record.entries.filter { $0.owned && $0.state == .present }.count) {
            plan.held = candidates.map(\.libraryID)
            entries += candidates
        } else {
            next.pendingRemovals += candidates.map(\.libraryID)
        }

        let present = Set(contents.items.map(\.path))
        next.pending = next.pending.filter { present.contains($0.key) }
        next.failed = next.failed.filter { present.contains($0.key) }
        let referenced = Set(entries.map(\.libraryID))
        var seen = Set<String>()
        next.pendingRemovals = next.pendingRemovals.filter {
            installed.contains($0) && !referenced.contains($0) && seen.insert($0).inserted
        }
        next.entries = entries.sorted { $0.path < $1.path }
        plan.removals = next.pendingRemovals
        plan.record = next
        return plan
    }

    /// Whether removing `count` of a link's `total` wallpapers at once needs the user's go-ahead.
    /// A single removal never does, however small the folder.
    static func isMassRemoval(_ count: Int, of total: Int) -> Bool {
        count > 1 && (count > massRemovalCount || Double(count) > Double(total) * massRemovalShare)
    }

    /// Records what an import of `item` did. `importedID` is the id it has in the library now, or
    /// nil when it failed. A renamed file that was changed comes back under its new name's id; the
    /// item under the old one is then due for removal when Mirror deletions is on.
    static func recordImport(
        _ item: LinkedFolderScan.Item, importedID: String?, mirrorsDeletions: Bool,
        in record: inout LinkedFolderRecord
    ) {
        record.pending[item.path] = nil
        guard let id = importedID else {
            record.failed[item.path] = item.stamp
            return
        }
        record.failed[item.path] = nil
        let entry = LinkedFolderRecord.Entry(path: item.path, libraryID: id, stamp: item.stamp,
                                             fileID: item.fileID, owned: true)
        if let index = record.entries.firstIndex(where: { $0.path == item.path }) {
            let previous = record.entries[index].libraryID
            record.entries[index] = entry
            if previous != id, mirrorsDeletions, !record.entries.contains(where: { $0.libraryID == previous }) {
                record.pendingRemovals.append(previous)
            }
        } else {
            record.entries.append(entry)
            record.entries.sort { $0.path < $1.path }
        }
        record.pendingRemovals.removeAll { $0 == id }
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

    /// The user confirmed held removals: the entries leave the record and their items are due.
    static func confirmHeld(_ ids: [String], in record: inout LinkedFolderRecord) {
        let confirmed = Set(ids)
        record.entries.removeAll { confirmed.contains($0.libraryID) && $0.owned }
        record.pendingRemovals += ids.filter { id in !record.pendingRemovals.contains(id) }
    }

    /// The user kept held items: they stay in the library and are never removed for this folder.
    static func keepHeld(_ ids: [String], in record: inout LinkedFolderRecord) {
        let keep = Set(ids)
        for index in record.entries.indices where keep.contains(record.entries[index].libraryID) {
            record.entries[index].state = .missing
        }
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

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
        for entry in record.entries where !((entry.state == .leaving || entry.state == .held) && !installed.contains(entry.libraryID)) {
            // A path whose file is now one this entry's file moved away from (two files swapped
            // names) is matched by file id below, so each wallpaper stays with its own file. A new
            // file saved over the path (another id, found nowhere else) is still a change of it.
            if contents.present.contains(entry.path),
               !(entry.fileID.map { mine in
                   items[entry.path]?.fileID.map { $0 != mine } == true
                       && contents.items.contains { $0.fileID == mine && $0.path != entry.path }
               } ?? false) {
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
                if entry.state == .leaving || entry.state == .held {
                    entry.state = .present
                    entry.removalConfirmed = nil
                }
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
            } else if item.libraryID != entry.libraryID,
                      installed.contains(item.libraryID)
                        || (item.libraryID.lowercased() != entry.libraryID.lowercased()
                            && (installedKeys.contains(item.libraryID.lowercased()) || claimed.contains(item.libraryID.lowercased()))) {
                // Renamed and changed onto an id another wallpaper has (on a case-sensitive volume,
                // also one that differs only in case): never imported over it.
                next.pending[item.path] = nil
            } else if settled(item, in: &next, plan: &plan) {
                plan.imports.append(item)
                claimed.insert(item.libraryID.lowercased())
            }
            entries.append(entry)
        }

        // Ids of new files scheduled for import in this look.
        var reserved = Set<String>()
        for item in unmatched {
            let key = item.libraryID.lowercased()
            // A wallpaper of the same id only in case that is installed separately (a case-sensitive
            // volume) is somebody else's: the returning file never reclaims through it.
            let reclaimable = { (id: String) in id == item.libraryID || !installed.contains(item.libraryID) }
            if !reserved.contains(key), let index = next.pendingRemovals.firstIndex(where: { $0.lowercased() == key }),
               installed.contains(next.pendingRemovals[index]), reclaimable(next.pendingRemovals[index]) {
                // Back before its wallpaper was removed: it stays, and is imported over it once
                // settled, since its contents may differ from what the library holds.
                let id = next.pendingRemovals.remove(at: index)
                entries.append(.init(path: item.path, libraryID: id, stamp: unknownStamp, fileID: item.fileID, owned: true))
                claimed.insert(key)
                plan.needsRecheck = true
            } else if !reserved.contains(key), let index = next.heldRemovals.firstIndex(where: { $0.lowercased() == key }),
                      installed.contains(next.heldRemovals[index]), reclaimable(next.heldRemovals[index]) {
                // Back while its removal was held: it stays, is no longer asked about, and is
                // imported over it once settled.
                let id = next.heldRemovals.remove(at: index)
                entries.append(.init(path: item.path, libraryID: id, stamp: unknownStamp, fileID: item.fileID, owned: true))
                claimed.insert(key)
                plan.needsRecheck = true
            } else if reserved.contains(key) {
                // Another new file of this id is being imported in this look: this one is looked at
                // again next time, recorded as nobody's only once that import has landed.
                continue
            } else if installedKeys.contains(key) || claimed.contains(key) {
                // Somebody else's item of the same id: recorded, never replaced or removed.
                entries.append(.init(path: item.path, libraryID: item.libraryID, stamp: item.stamp,
                                     fileID: item.fileID, owned: false))
                claimed.insert(key)
                next.pending[item.path] = nil
            } else if settled(item, in: &next, plan: &plan) {
                // Reserved, so a second new file of the same id in this look is not imported over it.
                plan.imports.append(item)
                reserved.insert(key)
            }
        }

        for var entry in departed where entry.owned {
            if !mirrorsDeletions {
                entry.state = .missing
            } else if entry.state == .present {
                entry.state = .leaving
                entry.removalConfirmed = nil
            }
            entries.append(entry)
        }

        let present = Set(contents.items.map(\.path))
        next.pending = next.pending.filter { present.contains($0.key) }
        next.failed = next.failed.filter { present.contains($0.key) }
        let referenced = Set(entries.filter { $0.state != .leaving }.map(\.libraryID))
        var seen = Set<String>()
        next.pendingRemovals = mirrorsDeletions ? next.pendingRemovals.filter {
            installed.contains($0) && !referenced.contains($0) && seen.insert($0).inserted
        } : []
        next.heldRemovals = mirrorsDeletions ? next.heldRemovals.filter {
            installed.contains($0) && !referenced.contains($0) && seen.insert($0).inserted
        } : []
        next.entries = entries.sorted { $0.path < $1.path }
        plan.held = holdMassRemovals(in: &next, beforeScan: record.entries)
        plan.removals = dueRemovals(next, installed: installed)
        plan.record = next
        return plan
    }

    /// The library items `record` has decided to remove and that are still installed: the
    /// wallpapers of files that left, and items no file stands for any more.
    /// Only exact ids: a wallpaper that matches only by case may be somebody else's on a
    /// case-sensitive volume. `recordImport` keeps the library's spelling, so the link's own ids
    /// match exactly.
    static func dueRemovals(_ record: LinkedFolderRecord, installed: Set<String>) -> [String] {
        let keep = Set(record.entries.filter { $0.state != .leaving }.map { $0.libraryID.lowercased() })
        var seen = Set<String>()
        return (record.entries.filter { $0.state == .leaving && $0.owned }.map(\.libraryID) + record.pendingRemovals)
            .filter { installed.contains($0) && !keep.contains($0.lowercased()) && seen.insert($0).inserted }
    }

    /// Never equal to a file's stamp: an entry that has it is imported over at its next settled look.
    static let unknownStamp = LinkedFolderStamp(size: -1, modified: 0)

    /// Whether removing `count` of a link's `total` wallpapers at once needs the user's go-ahead.
    /// A single removal never does, however small the folder.
    static func isMassRemoval(_ count: Int, of total: Int) -> Bool {
        count > 1 && (count > massRemovalCount || Double(count) > Double(total) * massRemovalShare)
    }

    /// Records what an import of `item` did. `importedID` is the id it has in the library now, or
    /// nil when it failed. Ownership requires a receipt from the importer for the copy on disk.
    /// A renamed file that was changed comes back
    /// under its new name's id; the item under the old one is then due for removal when Mirror
    /// deletions is on.
    @discardableResult static func recordImport(
        _ item: LinkedFolderScan.Item, importedID: String?, owned: Bool, mirrorsDeletions: Bool,
        installedBefore: Set<String>, in record: inout LinkedFolderRecord
    ) -> String? {
        record.pending[item.path] = nil
        guard var id = importedID else {
            record.failed[item.path] = item.stamp
            return nil
        }
        record.failed[item.path] = nil
        let index = record.entries.firstIndex(where: { $0.path == item.path })
        let previous = index.map { record.entries[$0] }
        // On a volume that ignores case, a file renamed only in case lands in the folder the
        // library already had, under its old spelling: the entry keeps that spelling.
        if let previous, previous.libraryID != id, previous.libraryID.lowercased() == id.lowercased(),
           installedBefore.contains(previous.libraryID), !installedBefore.contains(id) {
            id = previous.libraryID
        }
        let entry = LinkedFolderRecord.Entry(path: item.path, libraryID: id, stamp: item.stamp,
                                             fileID: item.fileID, owned: owned)
        if let index, let previous {
            record.entries[index] = entry
            // Compared without case: on the usual case-insensitive library volume a rename that
            // only changes case lands in the same folder, which must not then be removed.
            let old = previous.libraryID.lowercased()
            if owned, previous.owned, old != id.lowercased(), mirrorsDeletions,
               !record.entries.contains(where: { $0.libraryID.lowercased() == old }) {
                record.pendingRemovals.append(previous.libraryID)
            }
        } else {
            record.entries.append(entry)
            record.entries.sort { $0.path < $1.path }
        }
        if owned { record.pendingRemovals.removeAll { $0 == id } }
        return id
    }

    /// What an import report says became of `item`: the id it has in the library (identical
    /// content already there counts), a failure, or not reached by a cancelled import.
    static func outcome(of item: LinkedFolderScan.Item, in report: WallpaperImportService.Report) -> Outcome {
        if report.failures.contains(where: { $0.hasPrefix(item.path + ": ") }) { return .failed }
        let id = report.recognizedWorkshopIDs[item.path] ?? item.libraryID
        if report.importedIDs.contains(id) || report.skipped.contains(item.path) { return .imported(id) }
        return report.cancelled ? .notReached : .failed
    }

    enum Outcome: Equatable, Sendable {
        case imported(String)
        case failed
        case notReached
    }

    /// After a scan or import, weighs every unconfirmed departure and replacement together.
    /// Once held, each item waits for a decision even if the rest of the batch is confirmed.
    static func holdMassRemovals(
        in record: inout LinkedFolderRecord, beforeScan: [LinkedFolderRecord.Entry]? = nil
    ) -> [String] {
        let confirmed = record.confirmedReplacements?.intersection(record.pendingRemovals) ?? []
        record.confirmedReplacements = confirmed.isEmpty ? nil : confirmed
        let replacements = record.pendingRemovals.filter { !confirmed.contains($0) }
        let departures = record.entries.indices.filter {
            let entry = record.entries[$0]
            return entry.owned && (entry.state == .held || (entry.state == .leaving && entry.removalConfirmed != true))
        }
        let total = (beforeScan ?? record.entries).lazy.filter {
            $0.owned && $0.state != .missing && !($0.state == .leaving && $0.removalConfirmed == true)
        }.count
        let alreadyHeld = !record.heldRemovals.isEmpty || departures.contains { record.entries[$0].state == .held }
        guard alreadyHeld || isMassRemoval(departures.count + replacements.count, of: total) else { return [] }
        for index in departures { record.entries[index].state = .held }
        record.pendingRemovals.removeAll { !confirmed.contains($0) }
        record.heldRemovals += replacements
        return departures.map { record.entries[$0].libraryID } + record.heldRemovals
    }

    /// The user confirmed held removals: those files' wallpapers are due to be removed.
    static func confirmHeld(_ ids: [String], in record: inout LinkedFolderRecord) {
        let confirmed = Set(ids)
        let replaced = record.heldRemovals.filter { confirmed.contains($0) }
        record.heldRemovals.removeAll { confirmed.contains($0) }
        record.pendingRemovals += replaced.filter { !record.pendingRemovals.contains($0) }
        if !replaced.isEmpty {
            record.confirmedReplacements = (record.confirmedReplacements ?? []).union(replaced)
        }
        for index in record.entries.indices
        where confirmed.contains(record.entries[index].libraryID) && record.entries[index].owned
            && record.entries[index].state == .held {
            record.entries[index].state = .leaving
            record.entries[index].removalConfirmed = true
        }
    }

    /// The user kept held items: they stay in the library and are never removed for this folder.
    static func keepHeld(_ ids: [String], in record: inout LinkedFolderRecord) {
        let keep = Set(ids)
        record.heldRemovals.removeAll { keep.contains($0) }
        for index in record.entries.indices
        where keep.contains(record.entries[index].libraryID) && record.entries[index].state == .held {
            record.entries[index].state = .missing
        }
    }

    /// Mirror deletions went off: nothing still due is removed; those wallpapers are kept.
    static func stopMirroring(_ record: inout LinkedFolderRecord) {
        for index in record.entries.indices where record.entries[index].state == .leaving || record.entries[index].state == .held {
            record.entries[index].state = .missing
        }
        record.pendingRemovals = []
        record.heldRemovals = []
        record.confirmedReplacements = nil
    }

    /// `ids` left the library: their leaving entries and queued removals are done.
    static func recordRemoved(_ ids: Set<String>, in record: inout LinkedFolderRecord) {
        record.entries.removeAll { $0.state == .leaving && ids.contains($0.libraryID) }
        record.pendingRemovals.removeAll { ids.contains($0) }
        record.confirmedReplacements?.subtract(ids)
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

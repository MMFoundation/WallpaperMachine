import Foundation

enum FileLocation {
    /// URL equality also compares directory hints and trailing slashes.
    nonisolated static func isSame(_ first: URL, _ second: URL) -> Bool {
        first.resolvingSymlinksInPath().standardizedFileURL.path
            == second.resolvingSymlinksInPath().standardizedFileURL.path
    }

    nonisolated static func hasStagingName(_ url: URL, prefix: String) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }
}

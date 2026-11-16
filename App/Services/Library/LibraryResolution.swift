import AVFoundation
import Foundation
import ImageIO

/// Content dimensions read without playing a wallpaper, or the resolution tag Steam supplies.
enum LibraryResolution {
    private static let taggedSize = try! NSRegularExpression(
        pattern: #"^(?:(?:Ultrawide|Dual|Triple|Portrait) )?(?:[1-9][0-9]{0,5} x [1-9][0-9]{0,5}|Standard Definition)$"#)

    static func tag(in tags: [String]) -> String? {
        tags.first {
            ["Dynamic resolution", "Other resolution", "Standard Definition"].contains($0)
                || taggedSize.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }
    }

    /// The caller runs on a background executor. Paths from a manifest never leave its folder;
    /// previews and web viewports are not evidence of the wallpaper's content dimensions.
    static func read(project: [String: Any], folder: URL) async -> String? {
        let type = (project["type"] as? String)?.lowercased()
        if type == "video", let file = localFile(project["file"], folder: folder) {
            let asset = AVURLAsset(url: file)
            defer { asset.cancelLoading() }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                return dimensions(width: abs(rect.width), height: abs(rect.height))
            }
        }
        if type == "web" {
            for key in ["image", "pixiv"] {
                guard let source = project[key] as? [String: Any],
                      let file = localFile(source["file"], folder: folder),
                      let image = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { continue }
                let rotated = (5...8).contains((properties[kCGImagePropertyOrientation] as? Int) ?? 1)
                return dimensions(width: rotated ? height : width, height: rotated ? width : height)
            }
        }
        if type == "scene", let file = localFile(project["file"], folder: folder),
           file.pathExtension.lowercased() == "json", let scene = readObject(file),
           let general = scene["general"] as? [String: Any], let ortho = general["orthogonalprojection"] as? [String: Any],
           ortho["auto"] as? Bool != true,
           let width = (ortho["width"] as? NSNumber)?.doubleValue,
           let height = (ortho["height"] as? NSNumber)?.doubleValue {
            return dimensions(width: width, height: height)
        }
        return nil
    }

    static func readObject(_ file: URL) -> [String: Any]? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_000_000,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func localFile(_ value: Any?, folder: URL) -> URL? {
        guard let name = value as? String, !name.isEmpty, !name.hasPrefix("/"), !name.contains("\0") else { return nil }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }

    private static func dimensions(width: Double, height: Double) -> String? {
        guard width.isFinite, height.isFinite, width.rounded() >= 1, height.rounded() >= 1,
              width <= 131_072, height <= 131_072 else { return nil }
        return "\(Int(width.rounded())) × \(Int(height.rounded()))"
    }
}

import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import WallpaperMachine

final class LibraryResolutionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("library-resolution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testResolutionTagsKeepTheirFamilyAndRejectUnrelatedTags() {
        for tag in ["3840 x 2160", "Portrait 1080 x 1920", "Ultrawide 3440 x 1440", "Dual Standard Definition",
                    "Standard Definition", "Dynamic resolution", "Other resolution"] {
            XCTAssertEqual(LibraryResolution.tag(in: ["Anime", tag, "Video"]), tag)
        }
        XCTAssertNil(LibraryResolution.tag(in: ["Anime", "4K", "1920", "0 x 1080", "Customizable"]))
    }

    func testRotatedVideoUsesItsDisplayDimensionsWithoutPlayback() async throws {
        var request = SyntheticVideoFixture.Request.constantRate(name: "portrait", numerator: 24, denominator: 1, frames: 2)
        request.rotationDegrees = 90
        let file = try await SyntheticVideoFixture.write(request, into: root)
        let resolution = await LibraryResolution.read(project: ["type": "video", "file": file.lastPathComponent], folder: root)
        XCTAssertEqual(resolution, "36 × 64")
    }

    func testPackagedImageUsesTheOriginalImageAndNeverThePreview() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let file = root.appendingPathComponent("image.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let project: [String: Any] = ["type": "web", "file": "index.html", "preview": "image.png", "image": ["file": "image.png", "width": 1, "height": 1]]
        let resolution = await LibraryResolution.read(project: project, folder: root)
        XCTAssertEqual(resolution, "80 × 40", "read image metadata instead of trusting a stale manifest size")
        let web = await LibraryResolution.read(project: ["type": "web", "preview": "image.png"], folder: root)
        XCTAssertNil(web, "a web page's preview is not its resolution")
    }

    func testSceneReadsAuthoredCanvasAndLeavesAutomaticOrPackedScenesUnknown() async throws {
        let file = root.appendingPathComponent("scene.json")
        try Data(#"{"general":{"orthogonalprojection":{"width":2560,"height":1440}}}"#.utf8).write(to: file)
        let project: [String: Any] = ["type": "scene", "file": "scene.json"]
        let resolution = await LibraryResolution.read(project: project, folder: root)
        XCTAssertEqual(resolution, "2560 × 1440")
        try Data(#"{"general":{"orthogonalprojection":{"auto":true,"width":2560,"height":1440}}}"#.utf8).write(to: file)
        let automatic = await LibraryResolution.read(project: project, folder: root)
        XCTAssertNil(automatic)
        try FileManager.default.removeItem(at: file)
        let packed = await LibraryResolution.read(project: project, folder: root)
        XCTAssertNil(packed, "packed scenes fall back to Steam's tag without unpacking or rendering")
    }

    func testManifestPathsCannotReadOutsideTheWallpaper() async throws {
        let nested = root.appendingPathComponent("wallpaper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.json")
        try Data(#"{"general":{"orthogonalprojection":{"width":1920,"height":1080}}}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("link.json"), withDestinationURL: outside)
        for name in ["../outside.json", outside.path, "link.json"] {
            let resolution = await LibraryResolution.read(project: ["type": "scene", "file": name], folder: nested)
            XCTAssertNil(resolution, name)
        }
    }
}

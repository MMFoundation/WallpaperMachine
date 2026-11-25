import Foundation
import XCTest

@testable import WallpaperMachine

final class SetupPackServiceTests: XCTestCase {
  private var root: URL!
  private var home: URL!
  private var support: URL!
  private var exportDir: URL!
  private var previousHome: String?
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    defaults = try TemporaryDefaults.make(for: self).defaults
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "setup-pack-tests-\(UUID().uuidString)", isDirectory: true)
    home = root.appendingPathComponent("Home", isDirectory: true)
    support = home.appendingPathComponent("Library/Application Support/WallpaperMachine", isDirectory: true)
    exportDir = root.appendingPathComponent("Exports", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
    previousHome = ProcessInfo.processInfo.environment["WALLPAPER_MACHINE_HOME"]
    setenv("WALLPAPER_MACHINE_HOME", home.path, 1)
  }

  override func tearDownWithError() throws {
    if let previousHome {
      setenv("WALLPAPER_MACHINE_HOME", previousHome, 1)
    } else {
      unsetenv("WALLPAPER_MACHINE_HOME")
    }
    try? FileManager.default.removeItem(at: root)
  }

  private func service(limits: SetupPackLimits = .init()) -> SetupPackService {
    SetupPackService(supportRoot: support, storageRoot: support, limits: limits)
  }

  // MARK: - Export sanitization

  func testExportStripsCredentialsSpaceUUIDsLocalPathsAndMediaBinaries() throws {
    let packService = service()
    let secretSpaceUUID = "SPACE-UUID-PRIVATE-9999"
    let hardwareUUID = "HW-UUID-PRIVATE-1234"
    let localPreset = WallpaperPropertyPreset(
      id: UUID().uuidString,
      wallpaperID: "2841234567",
      name: "Midnight Neon",
      properties: [
        WallpaperPresetProperty(
          id: "speed", kind: "slider", value: .number(1.5), usesDefault: false, retainedPath: nil),
        WallpaperPresetProperty(
          id: "custom_image", kind: "file",
          value: .string("/Users/alice/Pictures/private-photo.png"), usesDefault: false,
          retainedPath: "/Users/alice/Library/Application Support/WallpaperMachine/UserAssets/PresetAssets/abc/custom_image/private.png"),
        WallpaperPresetProperty(
          id: "custom_tex", kind: "texture",
          value: .string("/Users/alice/Desktop/secret.tex"), usesDefault: false, retainedPath: nil),
        WallpaperPresetProperty(
          id: "builtin_tex", kind: "texture",
          value: .string("materials/starfield.tex"), usesDefault: false, retainedPath: nil),
      ])
    let nonWorkshopPreset = WallpaperPropertyPreset(
      id: UUID().uuidString,
      wallpaperID: "image-local-99",
      name: "Local Only Preset",
      properties: [])

    var spaceWidget = DesktopWidget(id: UUID().uuidString, kind: .time)
    spaceWidget.scope = .spaces([secretSpaceUUID, "SPACE-UUID-PRIVATE-8888"])
    spaceWidget.placement = .display(uuid: hardwareUUID, name: "Studio Display")

    var stickerWidget = DesktopWidget(id: UUID().uuidString, kind: .image)
    stickerWidget.imageAsset = DesktopWidget.ImageAsset(
      assetID: "asset-1", fileName: "sticker.png", displayName: "Sticker")

    let layout = WallpaperDisplayLayout(
      id: UUID().uuidString,
      name: "Dual Monitor Setup",
      assignments: [
        WallpaperDisplayAssignment(
          displayID: "primary", displayTitle: "Studio Display (1 - Primary)", wallpaperID: "2841234567"),
        WallpaperDisplayAssignment(
          displayID: "2", displayTitle: "Side Display (2 - Secondary)", wallpaperID: "image-local-99"),
      ],
      autoApplyOnConnect: true)

    let input = SetupPackExportInput(
      name: "Shared Setup",
      displays: [
        SetupPackTargetDisplay(
          displayID: "primary", displayUUID: hardwareUUID, title: "Studio Display (1 - Primary)",
          isPrimary: true, width: 2560, height: 1440),
      ],
      libraryTitles: ["2841234567": "Cyberpunk Rain"],
      activeWallpaperIDs: ["2841234567", "pixiv-12345"],
      presets: [localPreset, nonWorkshopPreset],
      widgets: [spaceWidget, stickerWidget],
      layouts: [layout])

    let destination = exportDir.appendingPathComponent("shared.wmpack")
    let report = try packService.export(to: destination, input: input)
    let rawBytes = try Data(contentsOf: destination)
    let rawText = try XCTUnwrap(String(data: rawBytes, encoding: .utf8))

    // Zero secrets, zero Space UUIDs, zero local user paths, zero hardware UUIDs, zero non-Workshop IDs.
    XCTAssertFalse(rawText.contains(secretSpaceUUID))
    XCTAssertFalse(rawText.contains("SPACE-UUID-PRIVATE"))
    XCTAssertFalse(rawText.contains("/Users/alice"))
    XCTAssertFalse(rawText.contains(hardwareUUID))
    XCTAssertFalse(rawText.contains("image-local-99"))
    XCTAssertFalse(rawText.contains("pixiv-12345"))
    XCTAssertFalse(rawText.contains("sticker.png"))
    XCTAssertFalse(rawText.contains("retainedPath"))

    XCTAssertEqual(report.workshopItemCount, 1)
    XCTAssertEqual(report.presetCount, 1)
    XCTAssertEqual(report.widgetCount, 1)
    XCTAssertEqual(report.layoutCount, 1)
    XCTAssertEqual(report.sanitization.downgradedSpaceWidgets, 1)
    XCTAssertEqual(report.sanitization.omittedImageWidgets, 1)
    XCTAssertEqual(report.sanitization.omittedNonWorkshopPresets, 1)
    XCTAssertEqual(report.sanitization.omittedNonWorkshopAssignments, 1)
    XCTAssertGreaterThanOrEqual(report.sanitization.strippedPresetPaths, 2)
    XCTAssertFalse(report.notes.isEmpty)

    // Decoded document has clean portable values.
    let (decoded, _) = try packService.parseAndValidate(data: rawBytes)
    XCTAssertEqual(decoded.widgets.count, 1)
    XCTAssertEqual(decoded.widgets[0].scope, .everywhere)
    XCTAssertEqual(decoded.presets.count, 1)
    XCTAssertTrue(decoded.presets[0].assets.isEmpty)
    XCTAssertEqual(decoded.presets[0].preset.properties[0].value, .number(1.5))
    XCTAssertTrue(decoded.presets[0].preset.properties[1].usesDefault)
    XCTAssertNil(decoded.presets[0].preset.properties[1].retainedPath)
    XCTAssertTrue(decoded.presets[0].preset.properties[2].usesDefault)
    XCTAssertEqual(decoded.presets[0].preset.properties[3].value, .string("materials/starfield.tex"))

    // Refuses exporting inside WallpaperMachine support folder or without `.wmpack`.
    XCTAssertThrowsError(
      try packService.export(to: support.appendingPathComponent("inside.wmpack"), input: input))
    XCTAssertThrowsError(
      try packService.export(to: exportDir.appendingPathComponent("wrong.json"), input: input))
  }

  // MARK: - Strict validation & hygiene

  func testStrictValidationRejectsOversizedDeepMalformedUTF8BadVersionTraversalAndNonNumericWorkshopIDs() throws {
    let packService = service()

    // 1. Empty & oversized payload
    XCTAssertThrowsError(try packService.parseAndValidate(data: Data()))
    let smallLimits = SetupPackLimits(maximumFileBytes: 128)
    let strictSmall = service(limits: smallLimits)
    XCTAssertThrowsError(
      try strictSmall.parseAndValidate(data: Data(repeating: 0x20, count: 200)))

    // 2. Malformed UTF-8 & NUL byte
    XCTAssertThrowsError(try packService.parseAndValidate(data: Data([0x7B, 0xFF, 0xFE, 0x7D])))
    XCTAssertThrowsError(try packService.parseAndValidate(data: Data("{\"format\":\"a\0b\"}".utf8)))

    // 3. Excessively deep JSON rejected in linear time before recursion
    let deep = String(repeating: "[", count: 40) + String(repeating: "]", count: 40)
    XCTAssertThrowsError(try packService.parseAndValidate(data: Data(deep.utf8)))

    // 4. Symlink rejected on file read
    let validPack = exportDir.appendingPathComponent("valid.wmpack")
    let validInput = SetupPackExportInput(activeWallpaperIDs: ["123456789"])
    _ = try packService.export(to: validPack, input: validInput)
    let symlinkURL = exportDir.appendingPathComponent("link.wmpack")
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: validPack)
    XCTAssertThrowsError(
      try packService.preview(fileAt: symlinkURL, installedWallpaperIDs: [], connectedDisplays: []))

    // 5. Unknown top-level key (e.g. credential injection)
    let unknownKeyJSON = """
    {
      "format": "app.wallpapermachine.setup-pack",
      "version": 1,
      "createdAt": "2026-11-25T12:00:00Z",
      "displays": [],
      "workshopItems": [{"id": "12345"}],
      "presets": [],
      "widgets": [],
      "layouts": [],
      "steamSession": "secret-token"
    }
    """
    XCTAssertThrowsError(try packService.parseAndValidate(data: Data(unknownKeyJSON.utf8)))

    // 6. Unsupported schema version
    let badVersionJSON = """
    {
      "format": "app.wallpapermachine.setup-pack",
      "version": 2,
      "createdAt": "2026-11-25T12:00:00Z",
      "displays": [],
      "workshopItems": [{"id": "12345"}],
      "presets": [],
      "widgets": [],
      "layouts": []
    }
    """
    XCTAssertThrowsError(try packService.parseAndValidate(data: Data(badVersionJSON.utf8)))

    // 7. Non-numeric / traversal Workshop IDs
    let badIDs = [
      "", "0", "00123", "-42", "abc", "../etc/passwd", "123/456", "123 456",
      "https://steamcommunity.com/sharedfiles/filedetails/?id=12345",
    ]
    for badID in badIDs {
      XCTAssertNil(SetupPackService.validatedWorkshopID(badID), "Expected rejection for \(badID)")
      let doc = SetupPackDocument(workshopItems: [SetupPackWorkshopItem(id: badID)])
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(doc)
      XCTAssertThrowsError(
        try packService.parseAndValidate(data: data), "Expected parse rejection for Workshop ID \(badID)")
    }

    // 8. Preset with binary attachments or external path rejected
    let presetWithBinary = WallpaperPresetDocument(
      preset: WallpaperPropertyPreset(
        id: UUID().uuidString, wallpaperID: "12345", name: "Bad", properties: []),
      assets: ["img": [.init(name: "x.png", bytes: Data([1, 2, 3]))]])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    XCTAssertThrowsError(
      try packService.parseAndValidate(data: try encoder.encode(SetupPackDocument(presets: [presetWithBinary]))))

    let presetWithLocalPath = WallpaperPresetDocument(
      preset: WallpaperPropertyPreset(
        id: UUID().uuidString, wallpaperID: "12345", name: "PathLeak",
        properties: [
          WallpaperPresetProperty(
            id: "f", kind: "file", value: .string("/etc/passwd"), usesDefault: false, retainedPath: nil),
        ]))
    XCTAssertThrowsError(
      try packService.parseAndValidate(data: try encoder.encode(SetupPackDocument(presets: [presetWithLocalPath]))))

    // 9. Path traversal in display slot ID rejected
    let badLayout = WallpaperDisplayLayout(
      name: "Traversal",
      assignments: [
        WallpaperDisplayAssignment(displayID: "../escape", displayTitle: "Bad", wallpaperID: "12345"),
      ])
    XCTAssertThrowsError(
      try packService.parseAndValidate(data: try encoder.encode(SetupPackDocument(layouts: [badLayout]))))

    // 10. Crafted incoming Space-pinned widget is downgraded to `.everywhere` with warning (never imported as Space UUID)
    var craftedSpaceWidget = DesktopWidget(id: UUID().uuidString, kind: .date)
    craftedSpaceWidget.scope = .spaces(["FOREIGN-SPACE-UUID"])
    let craftedData = try encoder.encode(SetupPackDocument(widgets: [craftedSpaceWidget]))
    let (sanitizedDoc, warnings) = try packService.parseAndValidate(data: craftedData)
    XCTAssertEqual(sanitizedDoc.widgets.first?.scope, .everywhere)
    XCTAssertFalse(warnings.isEmpty)
  }

  // MARK: - Display remapping

  func testDisplayUUIDRemappingAutomaticBestFitAndInteractiveOverride() throws {
    let packService = service()
    let sourceDisplays = [
      SetupPackTargetDisplay(
        displayID: "primary", displayUUID: "SRC-MAIN", title: "Built-in Retina Display (1 - Primary)",
        isPrimary: true, width: 1728, height: 1117),
      SetupPackTargetDisplay(
        displayID: "2", displayUUID: "SRC-EXT", title: "Studio Display (2 - Secondary)",
        isPrimary: false, width: 2560, height: 1440),
    ]
    var pinnedWidget = DesktopWidget(id: UUID().uuidString, kind: .time)
    pinnedWidget.placement = .display(uuid: "SRC-EXT", name: "Studio Display")
    let layout = WallpaperDisplayLayout(
      name: "Work Desk",
      assignments: [
        WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Built-in", wallpaperID: "1001"),
        WallpaperDisplayAssignment(displayID: "2", displayTitle: "Studio", wallpaperID: "2002"),
      ])

    let (_, data, _) = try packService.buildDocument(
      from: SetupPackExportInput(
        displays: sourceDisplays,
        widgets: [pinnedWidget],
        layouts: [layout]))

    let recipientDisplays = [
      SetupPackTargetDisplay(
        displayID: "primary", displayUUID: "DST-MAIN-UUID", title: "MacBook Pro (1 - Primary)",
        isPrimary: true, width: 1512, height: 982),
      SetupPackTargetDisplay(
        displayID: "9", displayUUID: "DST-EXT-UUID", title: "Pro Display XDR (9 - Secondary)",
        isPrimary: false, width: 2560, height: 1440),
    ]

    let preview = try packService.preview(
      data: data, fileName: "desk.wmpack", installedWallpaperIDs: ["1001"],
      connectedDisplays: recipientDisplays)

    // Primary maps to primary; secondary maps to secondary.
    XCTAssertEqual(preview.suggestedDisplayMapping["display-1"], "primary")
    XCTAssertEqual(preview.suggestedDisplayMapping["display-2"], "9")

    // Default plan remaps layout displayIDs and widget display UUID cleanly.
    let autoPlan = try packService.prepareImportPlan(
      preview: preview, options: SetupPackImportOptions(), connectedDisplays: recipientDisplays)
    XCTAssertEqual(autoPlan.layouts.count, 1)
    XCTAssertEqual(autoPlan.layouts[0].assignments.map(\.displayID), ["primary", "9"])
    XCTAssertEqual(
      autoPlan.widgets.first?.placement,
      .display(uuid: "DST-EXT-UUID", name: "Pro Display XDR (9 - Secondary)"))

    // Interactive override: user swaps displays or skips display-2.
    let skippedOptions = SetupPackImportOptions(
      displayMapping: ["display-1": "9", "display-2": nil])
    let skippedPlan = try packService.prepareImportPlan(
      preview: preview, options: skippedOptions, connectedDisplays: recipientDisplays)
    XCTAssertEqual(skippedPlan.layouts.count, 1)
    XCTAssertEqual(skippedPlan.layouts[0].assignments.map(\.displayID), ["9"])
    XCTAssertEqual(skippedPlan.layouts[0].assignments.map(\.wallpaperID), ["1001"])
    XCTAssertTrue(skippedPlan.widgets.isEmpty)

    // Single-display recipient deduplicates layout assignments so store validation always passes.
    let singleDisplay = [recipientDisplays[0]]
    let singlePreview = try packService.preview(
      data: data, fileName: "desk.wmpack", installedWallpaperIDs: ["1001", "2002"],
      connectedDisplays: singleDisplay)
    let singlePlan = try packService.prepareImportPlan(
      preview: singlePreview, options: SetupPackImportOptions(), connectedDisplays: singleDisplay)
    XCTAssertEqual(singlePlan.layouts.count, 1)
    XCTAssertEqual(singlePlan.layouts[0].assignments.count, 1)
    XCTAssertNoThrow(try WallpaperDisplayLayoutStore.validateAssignments(singlePlan.layouts[0].assignments))
  }

  // MARK: - Lossless round-trip & in-place store application

  @MainActor
  func testLosslessRoundTripOfPresetsLayoutsAndWidgetsPreservingUnrelatedState() throws {
    let packService = service()
    let preset = WallpaperPropertyPreset(
      id: UUID().uuidString,
      wallpaperID: "555001",
      name: "Cinema Warm",
      properties: [
        WallpaperPresetProperty(id: "bloom", kind: "bool", value: .bool(true), usesDefault: false, retainedPath: nil),
        WallpaperPresetProperty(id: "speed", kind: "slider", value: .number(0.85), usesDefault: false, retainedPath: nil),
        WallpaperPresetProperty(id: "theme", kind: "combo", value: .string("warm"), usesDefault: false, retainedPath: nil),
        WallpaperPresetProperty(
          id: "tint", kind: "color", value: .color(red: 0.9, green: 0.4, blue: 0.2), usesDefault: false,
          retainedPath: nil),
        WallpaperPresetProperty(id: "label", kind: "textInput", value: .string("Focus"), usesDefault: false, retainedPath: nil),
      ])

    var widget = DesktopWidget(id: UUID().uuidString, kind: .text)
    widget.text = "Stay Focused"
    widget.x = 0.2
    widget.y = 0.75
    widget.size = 44
    widget.color = "#FFAA33"
    widget.rotation = -12
    widget.scope = .wallpapers(["555001"])
    widget.placement = .main

    let layout = WallpaperDisplayLayout(
      name: "Evening Focus",
      assignments: [
        WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "555001"),
      ],
      autoApplyOnConnect: true)

    let target = SetupPackTargetDisplay(
      displayID: "primary", displayUUID: "MAIN-UUID", title: "Main Display", isPrimary: true)
    let packURL = exportDir.appendingPathComponent("roundtrip.wmpack")
    _ = try packService.export(
      to: packURL,
      input: SetupPackExportInput(
        name: "Focus Pack",
        displays: [target],
        libraryTitles: ["555001": "Rainy Loft"],
        presets: [preset],
        widgets: [widget],
        layouts: [layout]))

    let preview = try packService.preview(
      fileAt: packURL, installedWallpaperIDs: ["555001"], connectedDisplays: [target])
    XCTAssertEqual(preview.installedWorkshopItems.map(\.id), ["555001"])
    XCTAssertTrue(preview.missingWorkshopItems.isEmpty)

    let plan = try packService.prepareImportPlan(
      preview: preview, options: SetupPackImportOptions(), connectedDisplays: [target])

    // Seed pre-existing unrelated user data in isolated stores to prove nothing is clobbered.
    let presetStore = WallpaperPresetStore(
      defaults: defaults,
      managed: ManagedUserAssetStore(root: support.appendingPathComponent("UserAssets")))
    let layoutStore = WallpaperDisplayLayoutStore(defaults: defaults)
    let widgetStore = DesktopWidgetStore(defaults: defaults)

    let existingLayout = try layoutStore.save(
      name: "Existing Layout",
      assignments: [
        WallpaperDisplayAssignment(displayID: "other", displayTitle: "Other", wallpaperID: "999999"),
      ])
    let existingWidget = try widgetStore.add(.battery, placement: .all)

    let importedPresets = try presetStore.importPortablePresets(plan.presets)
    let importedWidgets = try widgetStore.add(plan.widgets)
    for importedLayout in plan.layouts {
      _ = try layoutStore.save(
        name: importedLayout.name,
        assignments: importedLayout.assignments,
        autoApplyOnConnect: importedLayout.autoApplyOnConnect)
    }

    // Verify lossless round-trip.
    XCTAssertEqual(importedPresets.count, 1)
    XCTAssertEqual(importedPresets[0].wallpaperID, preset.wallpaperID)
    XCTAssertEqual(importedPresets[0].name, preset.name)
    XCTAssertEqual(importedPresets[0].properties, preset.properties)

    XCTAssertEqual(importedWidgets.count, 1)
    XCTAssertEqual(importedWidgets[0].kind, .text)
    XCTAssertEqual(importedWidgets[0].text, "Stay Focused")
    XCTAssertEqual(importedWidgets[0].x, 0.2)
    XCTAssertEqual(importedWidgets[0].y, 0.75)
    XCTAssertEqual(importedWidgets[0].size, 44)
    XCTAssertEqual(importedWidgets[0].color, "#FFAA33")
    XCTAssertEqual(importedWidgets[0].rotation, -12)
    XCTAssertEqual(importedWidgets[0].scope, .wallpapers(["555001"]))

    XCTAssertEqual(layoutStore.layouts.count, 2)
    let restoredLayout = try XCTUnwrap(layoutStore.layouts.first { $0.name == "Evening Focus" })
    XCTAssertTrue(restoredLayout.autoApplyOnConnect)
    XCTAssertEqual(restoredLayout.assignments.map(\.wallpaperID), ["555001"])

    // Unrelated user data stayed intact.
    XCTAssertTrue(layoutStore.layouts.contains { $0.id == existingLayout.id })
    XCTAssertTrue(widgetStore.widgets.contains { $0.id == existingWidget.id })
  }
}

@MainActor
final class SetupPackControllerTests: PanelTestCase {
  func testImportRequiresExplicitConfirmationBeforeQueueingMissingWorkshopDownloads() async throws {
    try await withRecordingPanel { panel, _ in
      panel.store.librarySnapshot.wallpapers = [
        OrganizationFixtures.wallpaper("100001", title: "Already Installed"),
      ]
      let target = SetupPackTargetDisplay(
        displayID: "primary", displayUUID: "MAIN-UUID", title: "Main Display", isPrimary: true)
      let service = SetupPackService(supportRoot: panel.root, storageRoot: panel.root)
      let exportFile = panel.root.deletingLastPathComponent().appendingPathComponent(
        "confirm-\(UUID().uuidString).wmpack")
      defer { try? FileManager.default.removeItem(at: exportFile) }

      let preset = WallpaperPropertyPreset(
        id: UUID().uuidString, wallpaperID: "100001", name: "Saved Look",
        properties: [
          WallpaperPresetProperty(id: "glow", kind: "bool", value: .bool(true), usesDefault: false, retainedPath: nil),
        ])
      _ = try service.export(
        to: exportFile,
        input: SetupPackExportInput(
          name: "Confirmation Pack",
          displays: [target],
          libraryTitles: ["100001": "Already Installed", "200002": "Missing One", "300003": "Missing Two"],
          activeWallpaperIDs: ["100001", "200002", "300003"],
          presets: [preset]))

      let loadedPreview = try await panel.controller.previewSetupPack(at: exportFile, service: service)
      let preview = try XCTUnwrap(loadedPreview)
      XCTAssertEqual(preview.installedWorkshopItems.map(\.id), ["100001"])
      XCTAssertEqual(preview.missingWorkshopItems.map(\.id), ["200002", "300003"])

      // 1. Default options (queueMissingDownloadsConfirmed == false): NEVER queues any download.
      let reportWithoutDownload = try await panel.controller.applySetupPack(
        preview, options: SetupPackImportOptions(), service: service)
      XCTAssertEqual(reportWithoutDownload.importedPresetsCount, 1)
      XCTAssertEqual(reportWithoutDownload.queuedDownloadsCount, 0)
      XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)

      // 2. Opt-in requested, but user clicks Cancel on confirmation dialog: still ZERO downloads queued.
      panel.dialogs.confirmAnswer = false
      let reportDeclined = try await panel.controller.applySetupPack(
        preview,
        options: SetupPackImportOptions(
          includePresets: false, includeWidgets: false, includeLayouts: false,
          queueMissingDownloadsConfirmed: true),
        service: service)
      XCTAssertEqual(reportDeclined.queuedDownloadsCount, 0)
      XCTAssertTrue(panel.workshop.downloadRequests.isEmpty)

      // 3. Explicit confirmation granted: queues ONLY missing Workshop items (never already-installed 100001).
      panel.dialogs.confirmAnswer = true
      let reportConfirmed = try await panel.controller.applySetupPack(
        preview,
        options: SetupPackImportOptions(
          includePresets: false, includeWidgets: false, includeLayouts: false,
          queueMissingDownloadsConfirmed: true),
        service: service)
      XCTAssertEqual(reportConfirmed.queuedDownloadsCount, 2)
      XCTAssertEqual(Set(panel.workshop.downloadRequests.map(\.id)), Set(["200002", "300003"]))
    }
  }

  @MainActor
  func testPanelImportDoesNotClobberExistingAutoApplyLayoutOrArmImportedAutoApply() async throws {
    try await withPanel { panel in
      let existingUserLayout = try panel.controller.displayLayouts.save(
        name: "My Own Desk",
        assignments: [
          WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "999999"),
        ],
        autoApplyOnConnect: true)

      let target = SetupPackTargetDisplay(
        displayID: "primary", displayUUID: "MAIN-UUID", title: "Main Display", isPrimary: true)
      let service = SetupPackService(supportRoot: panel.root, storageRoot: panel.root)
      let exportFile = panel.root.deletingLastPathComponent().appendingPathComponent(
        "autoapply-\(UUID().uuidString).wmpack")
      defer { try? FileManager.default.removeItem(at: exportFile) }

      let sharedAutoLayout = WallpaperDisplayLayout(
        name: "Shared Auto Layout",
        assignments: [
          WallpaperDisplayAssignment(displayID: "primary", displayTitle: "Main", wallpaperID: "100001"),
        ],
        autoApplyOnConnect: true)
      _ = try service.export(
        to: exportFile,
        input: SetupPackExportInput(
          name: "Shared Pack",
          displays: [target],
          layouts: [sharedAutoLayout]))

      let loadedPreview = try await panel.controller.previewSetupPack(at: exportFile, service: service)
      let preview = try XCTUnwrap(loadedPreview)
      let report = try await panel.controller.applySetupPack(
        preview, options: SetupPackImportOptions(), service: service)
      XCTAssertEqual(report.importedLayoutsCount, 1)

      let refreshedUserLayout = try panel.controller.displayLayouts.layout(existingUserLayout.id)
      XCTAssertTrue(
        refreshedUserLayout.autoApplyOnConnect,
        "Importing a shared .wmpack must not disarm an existing user auto-apply layout")
      let imported = try XCTUnwrap(
        panel.controller.displayLayouts.layouts.first { $0.name == "Shared Auto Layout" })
      XCTAssertFalse(
        imported.autoApplyOnConnect,
        "Shared .wmpack display layouts must be saved with autoApplyOnConnect disabled")
    }
  }
}

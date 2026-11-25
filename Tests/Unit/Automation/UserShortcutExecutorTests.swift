import XCTest

@testable import WallpaperMachine

/// Verifies the hard security invariants of `UserShortcutStore`, `UserShortcutExecutor`,
/// `SceneMediaSink`, and Inspector shortcut presentation:
/// - Author-supplied `app:` / `shortcut:` defaults are NEVER executed.
/// - Only bindings explicitly approved by the user for `(wallpaperID, propertyID)` execute.
/// - Apple Shortcuts dispatch uses direct `/usr/bin/shortcuts` argv arrays (never shell interpolation).
/// - Strict per-shortcut cooldown and global burst rate limiting prevent per-frame spam launches.
@MainActor
final class UserShortcutExecutorTests: XCTestCase {
    private func makeIsolatedStore() throws -> (store: UserShortcutStore, defaults: UserDefaults) {
        let defaults = try TemporaryDefaults.make(for: self).defaults
        return (UserShortcutStore(defaults: defaults), defaults)
    }

    // MARK: - Hard Security Redline #1: Explicit User Approval Required

    func testAuthorSuppliedAppAndShortcutDefaultsAreStrictlyRejected() async throws {
        let (store, _) = try makeIsolatedStore()
        var launchedApps: [String] = []
        var ranShortcuts: [String] = []
        let executor = UserShortcutExecutor(
            store: store,
            runner: UserShortcutRunner(
                openApplication: { launchedApps.append($0); return true },
                runShortcut: { ranShortcuts.append($0); return true }))

        let appResult = await executor.execute(
            wallpaperID: "untrusted-wallpaper",
            propertyID: "launch_btn",
            value: "app:com.apple.Terminal")
        XCTAssertEqual(appResult, .rejectedUnapproved)

        let shortcutResult = await executor.execute(
            wallpaperID: "untrusted-wallpaper",
            propertyID: "run_btn",
            value: "shortcut:Erase Everything")
        XCTAssertEqual(shortcutResult, .rejectedUnapproved)

        XCTAssertTrue(launchedApps.isEmpty, "unapproved author defaults must never launch apps")
        XCTAssertTrue(ranShortcuts.isEmpty, "unapproved author defaults must never run Shortcuts")
    }

    func testApprovalIsScopedStrictlyToWallpaperPropertyAndExactTarget() async throws {
        let (store, _) = try makeIsolatedStore()
        try store.approve(
            wallpaperID: "wp-A",
            propertyID: "btn1",
            target: .application(bundleID: "com.apple.Safari"),
            displayName: "Safari")

        var launchedApps: [String] = []
        let executor = UserShortcutExecutor(
            store: store,
            runner: UserShortcutRunner(
                openApplication: { launchedApps.append($0); return true },
                runShortcut: { _ in true }))

        // Wrong wallpaper ID.
        let wrongWallpaper = await executor.execute(wallpaperID: "wp-B", propertyID: "btn1", value: "app:com.apple.Safari")
        XCTAssertEqual(wrongWallpaper, .rejectedUnapproved)
        // Wrong property ID.
        let wrongProperty = await executor.execute(wallpaperID: "wp-A", propertyID: "btn2", value: "app:com.apple.Safari")
        XCTAssertEqual(wrongProperty, .rejectedUnapproved)
        // Tampered target value for approved (wallpaper, property).
        let tamperedTarget = await executor.execute(wallpaperID: "wp-A", propertyID: "btn1", value: "app:com.apple.Terminal")
        XCTAssertEqual(tamperedTarget, .rejectedUnapproved)
        XCTAssertTrue(launchedApps.isEmpty)

        // Exact user-approved match executes cleanly.
        let ok = await executor.execute(wallpaperID: "wp-A", propertyID: "btn1", value: "app:com.apple.Safari")
        XCTAssertEqual(ok, .executed(.application(bundleID: "com.apple.Safari")))
        XCTAssertEqual(launchedApps, ["com.apple.Safari"])
    }

    func testApprovedShortcutUsesArgumentSafeDirectProcessArgumentsWithoutShellInterpolation() async throws {
        // Verify direct argv contract (never `sh -c`).
        XCTAssertEqual(UserShortcutRunner.shortcutsExecutablePath, "/usr/bin/shortcuts")
        XCTAssertEqual(
            UserShortcutRunner.shortcutsProcessArguments(for: "Morning Routine"),
            ["run", "Morning Routine"])
        // Even shell metacharacters inside a user-approved name stay a single literal argv element.
        XCTAssertEqual(
            UserShortcutRunner.shortcutsProcessArguments(for: "Focus & Music (Work)"),
            ["run", "Focus & Music (Work)"])

        // Reject unsafe or malformed Shortcut names (empty, whitespace, flag-injection `-`,
        // ASCII/C1 control characters, Unicode line/paragraph separators).
        for bad in [
            "", "   ", " leading", "trailing ", "-i", "--input-path",
            "a\nb", "a\0b", "a\rb", "a\u{0085}b", "a\u{009F}b", "a\u{2028}b", "a\u{2029}b",
        ] {
            XCTAssertNil(UserShortcutRunner.shortcutsProcessArguments(for: bad), "must reject \(bad.debugDescription)")
            XCTAssertNil(UserShortcutTarget(rawValue: "shortcut:\(bad)"), "must reject target \(bad.debugDescription)")
        }

        // Reject malformed bundle IDs.
        for badBundle in ["", "com.apple.Safari;rm", "../Safari", "-com.app", "com..app", "com.app "] {
            XCTAssertNil(UserShortcutTarget(rawValue: "app:\(badBundle)"), "must reject bundle \(badBundle.debugDescription)")
        }

        let (store, _) = try makeIsolatedStore()
        try store.approve(wallpaperID: "wp-1", propertyID: "morning", target: .shortcut(name: "Morning Routine"))

        var ranShortcuts: [String] = []
        let executor = UserShortcutExecutor(
            store: store,
            runner: UserShortcutRunner(
                openApplication: { _ in true },
                runShortcut: { ranShortcuts.append($0); return true }))

        let outcome = await executor.execute(
            wallpaperID: "wp-1", propertyID: "morning", value: "shortcut:Morning Routine")
        XCTAssertEqual(outcome, .executed(.shortcut(name: "Morning Routine")))
        XCTAssertEqual(ranShortcuts, ["Morning Routine"])
    }

    // MARK: - Hard Security Redline #2: Anti-Spam Cooldown & Global Burst Limiter

    func testPerShortcutCooldownBlocksRapidRepeatsAndAllowsAfterCooldownExpires() async throws {
        let (store, _) = try makeIsolatedStore()
        try store.approve(
            wallpaperID: "wp-1", propertyID: "launch",
            target: .application(bundleID: "com.apple.Notes"), displayName: "Notes")

        var clock: TimeInterval = 100.0
        var launchCount = 0
        let executor = UserShortcutExecutor(
            store: store,
            runner: UserShortcutRunner(
                openApplication: { _ in launchCount += 1; return true },
                runShortcut: { _ in true }),
            policy: .init(perShortcutCooldown: 1.5, globalBurstLimit: 3, globalBurstWindow: 10.0),
            now: { clock })

        // First trigger succeeds.
        let first = await executor.execute(wallpaperID: "wp-1", propertyID: "launch", value: "app:com.apple.Notes")
        XCTAssertEqual(first, .executed(.application(bundleID: "com.apple.Notes")))
        XCTAssertEqual(launchCount, 1)

        // Immediate per-frame spam is blocked.
        clock = 100.016
        guard case .rateLimitedPerShortcut(let retry1) = await executor.execute(
            wallpaperID: "wp-1", propertyID: "launch", value: "app:com.apple.Notes")
        else { return XCTFail("expected per-shortcut rate limit") }
        XCTAssertGreaterThan(retry1, 1.4)
        XCTAssertEqual(launchCount, 1)

        // Just before 1.5s is still blocked.
        clock = 101.49
        guard case .rateLimitedPerShortcut = await executor.execute(
            wallpaperID: "wp-1", propertyID: "launch", value: "app:com.apple.Notes")
        else { return XCTFail("expected per-shortcut rate limit at 1.49s") }
        XCTAssertEqual(launchCount, 1)

        // At >= 1.5s, launch succeeds again.
        clock = 101.50
        let afterCooldown = await executor.execute(wallpaperID: "wp-1", propertyID: "launch", value: "app:com.apple.Notes")
        XCTAssertEqual(afterCooldown, .executed(.application(bundleID: "com.apple.Notes")))
        XCTAssertEqual(launchCount, 2)
    }

    func testGlobalBurstLimiterCapsTotalLaunchesAcrossWallpapersAndProperties() async throws {
        let (store, _) = try makeIsolatedStore()
        try store.approve(wallpaperID: "wp-1", propertyID: "b1", target: .application(bundleID: "com.example.One"))
        try store.approve(wallpaperID: "wp-1", propertyID: "b2", target: .application(bundleID: "com.example.Two"))
        try store.approve(wallpaperID: "wp-2", propertyID: "b3", target: .shortcut(name: "Three"))
        try store.approve(wallpaperID: "wp-2", propertyID: "b4", target: .shortcut(name: "Four"))

        var clock: TimeInterval = 500.0
        var executions: [String] = []
        let executor = UserShortcutExecutor(
            store: store,
            runner: UserShortcutRunner(
                openApplication: { executions.append("app:\($0)"); return true },
                runShortcut: { executions.append("shortcut:\($0)"); return true }),
            policy: .init(perShortcutCooldown: 1.5, globalBurstLimit: 3, globalBurstWindow: 10.0),
            now: { clock })

        // First 3 distinct launches within 10s succeed.
        let r1 = await executor.execute(wallpaperID: "wp-1", propertyID: "b1", value: "app:com.example.One")
        XCTAssertEqual(r1, .executed(.application(bundleID: "com.example.One")))
        clock = 501.0
        let r2 = await executor.execute(wallpaperID: "wp-1", propertyID: "b2", value: "app:com.example.Two")
        XCTAssertEqual(r2, .executed(.application(bundleID: "com.example.Two")))
        clock = 502.0
        let r3 = await executor.execute(wallpaperID: "wp-2", propertyID: "b3", value: "shortcut:Three")
        XCTAssertEqual(r3, .executed(.shortcut(name: "Three")))

        // 4th launch within 10s window is blocked by global burst cap.
        clock = 503.0
        guard case .rateLimitedGlobalBurst(let retryAfter) = await executor.execute(
            wallpaperID: "wp-2", propertyID: "b4", value: "shortcut:Four")
        else { return XCTFail("expected global burst limit on 4th launch within 10s") }
        XCTAssertEqual(retryAfter, 7.0, accuracy: 0.01)
        XCTAssertEqual(executions.count, 3)

        // Once the 10s window slides past the 1st launch (t = 510.0), the 4th launch succeeds.
        clock = 510.0
        let r4 = await executor.execute(wallpaperID: "wp-2", propertyID: "b4", value: "shortcut:Four")
        XCTAssertEqual(r4, .executed(.shortcut(name: "Four")))
        XCTAssertEqual(executions, ["app:com.example.One", "app:com.example.Two", "shortcut:Three", "shortcut:Four"])
    }

    func testConcurrentReentrantTriggersCannotBypassCooldownWhileLaunchAwaits() async throws {
        let (store, _) = try makeIsolatedStore()
        try store.approve(wallpaperID: "wp-1", propertyID: "slow", target: .shortcut(name: "Slow Task"))

        var hold: CheckedContinuation<Bool, Never>?
        var invocations = 0
        let executor = UserShortcutExecutor(
            store: store,
            runner: UserShortcutRunner(
                openApplication: { _ in true },
                runShortcut: { _ in
                    invocations += 1
                    return await withCheckedContinuation { hold = $0 }
                }),
            now: { 200.0 })

        let firstTask = Task { @MainActor in
            await executor.execute(wallpaperID: "wp-1", propertyID: "slow", value: "shortcut:Slow Task")
        }
        while hold == nil { try await Task.sleep(for: .milliseconds(5)) }

        // A second trigger arriving while the first is still running must be rate-limited.
        let secondOutcome = await executor.execute(
            wallpaperID: "wp-1", propertyID: "slow", value: "shortcut:Slow Task")
        guard case .rateLimitedPerShortcut = secondOutcome else {
            hold?.resume(returning: true)
            _ = await firstTask.value
            return XCTFail("re-entrant trigger bypassed per-shortcut cooldown")
        }
        XCTAssertEqual(invocations, 1)

        hold?.resume(returning: true)
        let firstOutcome = await firstTask.value
        XCTAssertEqual(firstOutcome, .executed(.shortcut(name: "Slow Task")))
    }

    // MARK: - Store Persistence, Cleanup & Archive Validation

    func testStorePersistsReloadsRemovesAndValidatesArchiveData() throws {
        let (store, defaults) = try makeIsolatedStore()
        try store.approve(
            wallpaperID: "wp-1", propertyID: "open_app",
            target: .application(bundleID: "com.apple.Safari"), displayName: "Safari")
        try store.approve(
            wallpaperID: "wp-1", propertyID: "run_sc",
            target: .shortcut(name: "Focus Mode"))
        try store.approve(
            wallpaperID: "wp-2", propertyID: "other",
            target: .application(bundleID: "com.apple.Music"), displayName: "Music")

        // Reload from same isolated defaults.
        let reloaded = UserShortcutStore(defaults: defaults)
        XCTAssertEqual(reloaded.binding(wallpaperID: "wp-1", propertyID: "open_app")?.displayName, "Safari")
        XCTAssertEqual(reloaded.binding(wallpaperID: "wp-1", propertyID: "run_sc")?.target, .shortcut(name: "Focus Mode"))
        XCTAssertEqual(reloaded.allBindings().count, 3)

        // Removing one binding and then all bindings for a wallpaper persists cleanly.
        reloaded.remove(wallpaperID: "wp-1", propertyID: "open_app")
        XCTAssertNil(UserShortcutStore(defaults: defaults).binding(wallpaperID: "wp-1", propertyID: "open_app"))
        reloaded.removeAll(for: "wp-1")
        XCTAssertTrue(UserShortcutStore(defaults: defaults).bindings(for: "wp-1").isEmpty)
        XCTAssertEqual(UserShortcutStore(defaults: defaults).allBindings().count, 1)

        // Corrupt/tampered persisted data is ignored on load.
        let tampered = Data(#"{"wrong-key":{"wallpaperID":"wp","propertyID":"p","target":{"shortcut":{"name":"--flag"}},"approvedAt":0}}"#.utf8)
        defaults.set(tampered, forKey: UserShortcutStore.storageKey)
        XCTAssertTrue(UserShortcutStore(defaults: defaults).allBindings().isEmpty)
    }

    // MARK: - SceneMediaSink, Cross-Wallpaper Isolation, Non-Blocking Dispatch & Inspector Lifecycle

    func testSceneMediaSinkDispatchesMediaCommandsAndApprovedShortcutsWhileRejectingCrossWallpaperHijacking() async throws {
        let (store, _) = try makeIsolatedStore()
        try store.approve(
            wallpaperID: "scene-42", propertyID: "open_safari",
            target: .application(bundleID: "com.apple.Safari"), displayName: "Safari")
        try store.approve(
            wallpaperID: "scene-42", propertyID: "morning_sc",
            target: .shortcut(name: "Morning Routine"))

        var launchedApps: [String] = []
        var ranShortcuts: [String] = []
        let executor = UserShortcutExecutor(
            store: store,
            runner: UserShortcutRunner(
                openApplication: { launchedApps.append($0); return true },
                runShortcut: { ranShortcuts.append($0); return true }))

        // Empty wallpaper ID must fail closed even when an approved binding exists on another wallpaper.
        let emptyResult = await executor.execute(
            wallpaperID: "", propertyID: "open_safari", value: "app:com.apple.Safari")
        XCTAssertEqual(emptyResult, .rejectedUnapproved)

        // Different wallpaper attempting to hijack Display 1's approved binding must be strictly rejected.
        let hijackResult = await executor.execute(
            wallpaperID: "evil-display-2", propertyID: "open_safari", value: "app:com.apple.Safari")
        XCTAssertEqual(hijackResult, .rejectedUnapproved)
        XCTAssertTrue(launchedApps.isEmpty)

        let provider = ScriptedSystemMediaProvider()
        let session = DesktopMediaSession(provider: provider)
        let presses = AsyncPresses([
            BridgeUserShortcut(sceneHandle: 11, wallpaperId: "scene-42", property: "nextsong", value: "media:next"),
            // Cross-wallpaper spoof from Display 2 targeting Display 1's approved binding: MUST be rejected.
            BridgeUserShortcut(sceneHandle: 22, wallpaperId: "evil-display-2", property: "open_safari", value: "app:com.apple.Safari"),
            // Empty wallpaper ID: MUST fail closed.
            BridgeUserShortcut(sceneHandle: 22, wallpaperId: "", property: "morning_sc", value: "shortcut:Morning Routine"),
            // Unapproved property on scene-42: MUST be rejected.
            BridgeUserShortcut(sceneHandle: 11, wallpaperId: "scene-42", property: "evil_default", value: "app:com.apple.Terminal"),
            // Legitimate approved triggers on scene-42: MUST execute.
            BridgeUserShortcut(sceneHandle: 11, wallpaperId: "scene-42", property: "open_safari", value: "app:com.apple.Safari"),
            BridgeUserShortcut(sceneHandle: 11, wallpaperId: "scene-42", property: "morning_sc", value: "shortcut:Morning Routine"),
            BridgeUserShortcut(sceneHandle: 11, wallpaperId: "scene-42", property: "playpause", value: "media:playpause"),
        ])
        let sink = SceneMediaSink(
            session: session,
            submit: { _ in },
            applyArtwork: { _, _, _ in },
            fetchScenes: { [11: 0] },
            nextShortcut: { try await presses.next() },
            shortcutExecutor: executor)
        defer { sink.shutdown() }

        let deadline = Date().addingTimeInterval(2)
        while (provider.sentCommands.count < 2 || launchedApps.count < 1 || ranShortcuts.count < 1) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(provider.sentCommands, [.nextTrack, .togglePlayPause])
        XCTAssertEqual(launchedApps, ["com.apple.Safari"])
        XCTAssertEqual(ranShortcuts, ["Morning Routine"])
    }

    func testSlowShortcutDoesNotBlockMediaCommandsAndShutdownCancelsInFlightShortcut() async throws {
        let (store, _) = try makeIsolatedStore()
        try store.approve(
            wallpaperID: "scene-1", propertyID: "slow_sc",
            target: .shortcut(name: "Long Shortcut"))

        var startedShortcut = false
        var cancelledShortcut = false
        let executor = UserShortcutExecutor(
            store: store,
            runner: UserShortcutRunner(
                openApplication: { _ in true },
                runShortcut: { _ in
                    startedShortcut = true
                    do {
                        try await Task.sleep(for: .seconds(60))
                        return true
                    } catch {
                        cancelledShortcut = true
                        return false
                    }
                }))

        let provider = ScriptedSystemMediaProvider()
        let session = DesktopMediaSession(provider: provider)
        let presses = AsyncPresses([
            BridgeUserShortcut(sceneHandle: 11, wallpaperId: "scene-1", property: "slow_sc", value: "shortcut:Long Shortcut"),
            BridgeUserShortcut(sceneHandle: 11, wallpaperId: "scene-1", property: "next_btn", value: "media:next"),
        ])
        let sink = SceneMediaSink(
            session: session,
            submit: { _ in },
            applyArtwork: { _, _, _ in },
            fetchScenes: { [11: 0] },
            nextShortcut: { try await presses.next() },
            shortcutExecutor: executor)

        let deadline = Date().addingTimeInterval(2)
        while (!startedShortcut || provider.sentCommands.isEmpty) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(startedShortcut, "slow shortcut should have started")
        XCTAssertEqual(provider.sentCommands, [.nextTrack], "media commands must not stall behind a slow Shortcut")

        sink.shutdown()
        let cancelDeadline = Date().addingTimeInterval(2)
        while !cancelledShortcut && Date() < cancelDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(cancelledShortcut, "shutdown() must cancel in-flight Shortcut tasks")
    }

    func testRunProcessEnforcesBoundedTimeoutAndCancellation() async throws {
        let sleepURL = URL(fileURLWithPath: "/bin/sleep")
        guard FileManager.default.isExecutableFile(atPath: sleepURL.path) else { return }

        let timeoutStart = ContinuousClock.now
        let timedOutResult = await UserShortcutRunner.runProcess(
            executableURL: sleepURL, arguments: ["10"], timeout: .milliseconds(60))
        XCTAssertFalse(timedOutResult)
        XCTAssertLessThan(ContinuousClock.now - timeoutStart, .seconds(2))

        let cancelStart = ContinuousClock.now
        let task = Task {
            await UserShortcutRunner.runProcess(
                executableURL: sleepURL, arguments: ["10"], timeout: .seconds(10))
        }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        let cancelledResult = await task.value
        XCTAssertFalse(cancelledResult)
        XCTAssertLessThan(ContinuousClock.now - cancelStart, .seconds(2))
    }

    func testPresetStoreAcceptsCustomUserShortcutLocallyWhileStrippingItOnExportAndImport() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UserShortcutPresetTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempRoot) }

        let defaults = try TemporaryDefaults.make(for: self).defaults
        let store = WallpaperPresetStore(
            defaults: defaults,
            managed: ManagedUserAssetStore(root: tempRoot.appendingPathComponent("Assets")))

        let descriptor = BridgePropertyDescriptor(
            id: "launch",
            kind: .combo,
            labelHtml: "Launch",
            value: .string(value: "app:com.apple.Safari"),
            defaultValue: .string(value: ""),
            slider: nil,
            comboOptions: [
                BridgeComboOption(label: "No action", value: .string(value: "")),
                BridgeComboOption(label: "Play / Pause", value: .string(value: "media:playpause")),
                BridgeComboOption(label: "Next Track", value: .string(value: "media:next")),
                BridgeComboOption(label: "Previous Track", value: .string(value: "media:previous")),
            ],
            fileFilter: nil, directoryMode: nil,
            dirty: false, canRestoreDefaults: true, enabled: true,
            assetManaged: false, assetMissing: false, assetSourcePath: nil, staged: false)
        let options = BridgeSnapshotFixtures.options(
            wallpaperId: "wp-sc", kind: .projectScene, properties: [descriptor])

        // Local save succeeds even with a custom `app:` shortcut bound.
        let saved = try await store.save(name: "My Shortcuts", options: options, hasPendingEdits: false)
        XCTAssertEqual(saved.properties.first?.value, WallpaperPresetValue.string("app:com.apple.Safari"))

        // Export strips machine-local `app:` bindings so shared preset files never carry them.
        let exported = try await store.exportDocument(id: saved.id)
        let exportedText = String(decoding: exported, as: UTF8.self)
        XCTAssertFalse(exportedText.contains("app:com.apple.Safari"))

        // Importing a hand-crafted preset carrying an `app:` value strips it cleanly instead of smuggling it.
        let smuggledJSON = Data("""
        {
          "version": 1,
          "preset": {
            "id": "00000000-0000-0000-0000-000000000001",
            "wallpaperID": "wp-sc",
            "name": "Untrusted Import",
            "properties": [
              { "id": "launch", "kind": "combo", "value": { "string": { "_0": "app:com.apple.Terminal" } }, "usesDefault": false }
            ]
          },
          "assets": {}
        }
        """.utf8)
        let imported = try await store.importDocument(smuggledJSON, options: options)
        XCTAssertEqual(imported.properties.first?.value, WallpaperPresetValue.string(""))
        XCTAssertEqual(imported.properties.first?.usesDefault, true)
    }

    /// Inspector shortcut edits stay staged in memory until "Apply changes": closing the panel
    /// before Apply never arms an unapplied binding, clearing + Revert preserves the previously
    /// applied approval, and applying a preset prunes approvals that no longer match.
    func testInspectorDraftAppliesRevertsClosesAndPrunesOnPresetWithoutDesyncingStore() async throws {
        let context = try PanelPropertyContext()
        do {
            let shortcutProp = BridgePropertyDescriptor(
                id: "btn",
                kind: .combo,
                labelHtml: "Launch Button",
                value: .string(value: ""),
                defaultValue: .string(value: ""),
                slider: nil,
                comboOptions: [
                    BridgeComboOption(label: "No action", value: .string(value: "")),
                    BridgeComboOption(label: "Play / Pause", value: .string(value: "media:playpause")),
                    BridgeComboOption(label: "Next Track", value: .string(value: "media:next")),
                    BridgeComboOption(label: "Previous Track", value: .string(value: "media:previous")),
                ],
                fileFilter: nil, directoryMode: nil,
                dirty: false, canRestoreDefaults: false, enabled: true,
                assetManaged: false, assetMissing: false, assetSourcePath: nil, staged: false)
            let baseOptions = BridgeSnapshotFixtures.options(
                wallpaperId: "wp", title: "wp", kind: .projectScene, properties: [shortcutProp])
            context.bridge.options["wp"] = baseOptions
            context.store.wallpaperOptionsSnapshot = baseOptions
            context.bridge.editAnswer = { snapshot in
                var updated = snapshot
                updated.properties = updated.properties.map { property in
                    var property = property
                    property.canRestoreDefaults = property.value != property.defaultValue
                    return property
                }
                return updated
            }
            context.bridge.restoreAnswer = { propertyID, snapshot in
                var updated = snapshot
                updated.properties = updated.properties.map { property in
                    var property = property
                    if property.id == propertyID {
                        property.value = property.defaultValue
                        property.dirty = true
                        property.canRestoreDefaults = false
                    }
                    return property
                }
                return updated
            }

            try await context.panel.start()
            let controller = context.controller

            // 1. Save a "Clean" preset while unbound so we can apply it later to test pruning.
            let savedCleanPresetID = try await controller.savePreset("wp", name: "Clean")
            let cleanPresetID = try XCTUnwrap(savedCleanPresetID)

            // 2. Stage a custom shortcut binding — visible in Inspector draft, NOT yet armed in store.
            try await controller.bindUserShortcut("wp", property: "btn", shortcutName: "Morning")
            XCTAssertNil(
                controller.userShortcuts.binding(wallpaperID: "wp", propertyID: "btn"),
                "staging a shortcut must not persist approval before Apply changes")
            XCTAssertEqual(
                controller.inspectorOptions(for: "wp")?.properties.first(where: { $0.id == "btn" })?.control,
                .userShortcut(.init(selection: .shortcut(name: "Morning"))))

            // 3. Closing the panel without Apply drops staged approvals cleanly; store stays empty.
            controller.stop()
            XCTAssertTrue(controller.pendingUserShortcutEdits.isEmpty)
            XCTAssertNil(controller.userShortcuts.binding(wallpaperID: "wp", propertyID: "btn"))

            // 4. Re-open, stage and Apply -> approval is now persisted in UserShortcutStore.
            controller.start()
            try await controller.bindUserShortcut("wp", property: "btn", shortcutName: "Morning")
            try await controller.apply("wp")
            let appliedAfterMorning = try XCTUnwrap(context.bridge.options["wp"])
            context.bridge.cancelAnswer = { _ in appliedAfterMorning }
            XCTAssertEqual(
                controller.userShortcuts.binding(wallpaperID: "wp", propertyID: "btn")?.target,
                .shortcut(name: "Morning"))
            XCTAssertTrue(controller.pendingUserShortcutEdits.isEmpty)

            // 5. Stage clearing to "No action", then Revert -> existing approval stays intact!
            try await controller.setUserShortcutAction("wp", property: "btn", builtInValue: "")
            XCTAssertEqual(
                controller.userShortcuts.binding(wallpaperID: "wp", propertyID: "btn")?.target,
                .shortcut(name: "Morning"),
                "clearing before Apply must not wipe applied approval in case the user reverts")
            try await controller.revert("wp")
            XCTAssertEqual(
                controller.userShortcuts.binding(wallpaperID: "wp", propertyID: "btn")?.target,
                .shortcut(name: "Morning"),
                "Revert must restore both the bridge value and its existing approval")
            XCTAssertTrue(controller.pendingUserShortcutEdits.isEmpty)

            // 6. Applying the "Clean" preset sets `btn` back to "" and prunes the stale approval.
            try await controller.applyPreset("wp", preset: cleanPresetID)
            XCTAssertNil(
                controller.userShortcuts.binding(wallpaperID: "wp", propertyID: "btn"),
                "applyPreset must prune approvals that no longer match the applied wallpaper properties")
        } catch {
            await context.shutdown()
            throw error
        }
        await context.shutdown()
    }

    func testInspectorOptionsHideUnapprovedAuthorShortcutsAndShowExplicitlyApprovedBindings() throws {
        var descriptor = BridgePropertyDescriptor(
            id: "btn",
            kind: .combo,
            labelHtml: "Launch Button",
            value: .string(value: "app:com.apple.Terminal"),
            defaultValue: .string(value: ""),
            slider: nil,
            comboOptions: [
                BridgeComboOption(label: "No action", value: .string(value: "")),
                BridgeComboOption(label: "Play / Pause", value: .string(value: "media:playpause")),
                BridgeComboOption(label: "Next Track", value: .string(value: "media:next")),
                BridgeComboOption(label: "Previous Track", value: .string(value: "media:previous")),
            ],
            fileFilter: nil,
            directoryMode: nil,
            dirty: false,
            canRestoreDefaults: true,
            enabled: true,
            assetManaged: false,
            assetMissing: false,
            assetSourcePath: nil,
            staged: false)

        // Unapproved value is NEVER shown as a bound app.
        let unapproved = InspectorOptions.make(
            BridgeSnapshotFixtures.options(wallpaperId: "wp", kind: .projectScene, properties: [descriptor]))
        XCTAssertEqual(unapproved.properties.first?.control, .userShortcut(.init(selection: .none)))

        // Explicitly approved app binding shows display name + bundle ID.
        descriptor.value = .string(value: "app:com.apple.Safari")
        var inputs = InspectorOptions.Inputs()
        inputs.approvedShortcuts["btn"] = ApprovedUserShortcutBinding(
            wallpaperID: "wp", propertyID: "btn",
            target: .application(bundleID: "com.apple.Safari"),
            displayName: "Safari", approvedAt: Date())
        let approved = InspectorOptions.make(
            BridgeSnapshotFixtures.options(wallpaperId: "wp", kind: .projectScene, properties: [descriptor]),
            inputs: inputs)
        XCTAssertEqual(
            approved.properties.first?.control,
            .userShortcut(.init(selection: .application(bundleID: "com.apple.Safari", displayName: "Safari"))))
    }
}

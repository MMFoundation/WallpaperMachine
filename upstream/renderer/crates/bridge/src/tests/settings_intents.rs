use std::{
    sync::{Arc, mpsc},
    thread,
};

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySelector, DisplaySnapshotEntry,
    WallpaperAssignment,
    project::{SceneHandle, SceneTemplate},
};

use super::engine_release::EngineRelease;
use crate::{
    BridgeDisplayMode, BridgePropertyValue,
    WallpaperBridge,
    api::BridgeBuilder,
    config::{
        AppConfig, ConfigStore, MonitorCfg, SerializedSelector,
        WallpaperConfig,
    },
    engine::FakeEngineFacade,
    paths::BridgePaths,
};

#[tokio::test]
async fn stale_reconcile_failure_defers_repair_until_newer_reconcile_finishes() {
    let primary = identified_display("primary", 1);
    let secondary = identified_display("secondary", 3);
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    store
        .save_app_config(&AppConfig {
            monitors: vec![MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                mode: "independent".to_string(),
                wallpaper: Some("100".to_string()),
                mirror_target: None,
            }],
            ..AppConfig::default()
        })
        .unwrap();
    store
        .save_wallpaper(&WallpaperConfig::new_for("100", "scene"))
        .unwrap();

    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![primary, secondary]);
    let bridge = Arc::new(
        BridgeBuilder::new(engine.clone())
            .with_config_store(ConfigStore::open(root.path().to_path_buf()))
            .build()
            .expect("tokio runtime and config load for wallpaper bridge"),
    );
    bridge.bootstrap().await.unwrap();
    let calls_before = engine.calls().len();
    let secondary_display_id = settings_row_id_by_title(&bridge, "secondary").await;

    let first_block = engine.block_next_reconcile();
    let second_block = engine.block_next_reconcile();
    let (disable_tx, disable_rx) = mpsc::channel();
    let disable_bridge = Arc::clone(&bridge);
    let disable_display_id = secondary_display_id.clone();
    let disable = thread::spawn(move || {
        let result = tokio::runtime::Runtime::new().unwrap().block_on(async {
            disable_bridge
                .set_display_enabled(disable_display_id, false)
                .await
        });
        disable_tx.send(result).unwrap();
    });
    assert!(
        first_block.wait_until_blocked(std::time::Duration::from_secs(2)),
        "first display mutation did not reach reconcile"
    );

    let (mirror_tx, mirror_rx) = mpsc::channel();
    let mirror_bridge = Arc::clone(&bridge);
    let mirror_display_id = secondary_display_id.clone();
    let mirror = thread::spawn(move || {
        let result = tokio::runtime::Runtime::new().unwrap().block_on(async {
            mirror_bridge
                .set_display_mode(mirror_display_id, BridgeDisplayMode::Mirror)
                .await
        });
        mirror_tx.send(result).unwrap();
    });
    assert!(
        second_block.wait_until_blocked(std::time::Duration::from_secs(2)),
        "second display mutation did not reach reconcile"
    );

    engine.fail_reconcile_with("post-reconcile failure");
    first_block.release();
    disable_rx
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("first mutation should report reconcile failure")
        .expect_err("stale mutation should return the renderer failure");
    disable.join().unwrap();

    second_block.release();
    mirror_rx
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("second mutation should report reconcile failure")
        .expect_err("newer mutation should return the renderer failure");
    mirror.join().unwrap();

    tokio::time::timeout(std::time::Duration::from_secs(2), async {
        while engine.calls().len() < calls_before + 3 {
            tokio::task::yield_now().await;
        }
    }).await.expect("failed changes must request a committed-state repair");

    let display = settings_row(&bridge, &secondary_display_id).await;
    assert!(display.enabled);
    assert_eq!(display.mode, BridgeDisplayMode::Standalone);
    // If the first repair has already failed when the second failure arrives,
    // it is a fresh request. Coalescing an active repair still needs only one.
    assert!((3..=4).contains(&(engine.calls().len() - calls_before)));
}

#[tokio::test]
async fn first_seen_display_starts_with_primary_wallpaper_and_keeps_opt_out_after_reconnect() {
    let primary = identified_display("primary", 1);
    let mut external = identified_display("external", 3);
    // The engine has never shown this display, so it reports no window.
    external.window_active = false;
    let external_selector =
        SerializedSelector::from_selector(&DisplaySelector::Identity(external.identity.clone()));
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    store
        .save_app_config(&AppConfig {
            monitors: vec![MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                mode: "independent".to_string(),
                wallpaper: Some("100".to_string()),
                mirror_target: None,
            }],
            ..AppConfig::default()
        })
        .unwrap();
    store
        .save_wallpaper(&WallpaperConfig::new_for("100", "scene"))
        .unwrap();

    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![primary.clone()]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge.bootstrap().await.unwrap();

    engine.set_snapshot_after_refresh(vec![primary.clone(), external.clone()]);
    bridge.refresh_displays().await.unwrap();

    let external_id = settings_row_id_by_title(&bridge, "external").await;
    assert_display_enabled(&bridge, &external_id, true).await;
    assert_latest_scene(&engine, 1, "100");
    assert_latest_scene(&engine, 3, "100");

    bridge
        .set_display_enabled(external_id.clone(), false)
        .await
        .expect("external display should be disabled");
    engine.set_snapshot_after_refresh(vec![primary.clone()]);
    bridge.refresh_displays().await.unwrap();
    engine.set_snapshot_after_refresh(vec![primary, external]);
    bridge.refresh_displays().await.unwrap();

    assert_display_enabled(&bridge, &external_id, false).await;
    assert!(
        engine
            .calls()
            .last()
            .expect("reconcile call")
            .iter()
            .all(|scene| scene.display.display_id != 3),
        "a display the user turned off must stay dark when it reconnects"
    );
    let saved = store.load().unwrap().config;
    assert!(
        saved
            .monitors
            .iter()
            .any(|monitor| monitor.selector == external_selector && !monitor.enabled),
        "the opt-out must be saved under the display's identity"
    );
}

#[tokio::test]
async fn primary_wallpaper_stays_on_primary_after_primary_display_switch() {
    let display_a = identified_display("a", 1);
    let display_b = identified_display("b", 3);
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    store
        .save_app_config(&AppConfig {
            monitors: vec![MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                mode: "independent".to_string(),
                wallpaper: Some("300".to_string()),
                mirror_target: None,
            }],
            ..AppConfig::default()
        })
        .unwrap();
    store
        .save_wallpaper(&WallpaperConfig::new_for("300", "scene"))
        .unwrap();

    let engine = FakeEngineFacade::default();
    engine.set_snapshot_after_refresh(vec![display_a.clone(), display_b.clone()]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.bootstrap().await.unwrap();
    assert_latest_scene(&engine, 1, "300");

    engine.set_snapshot_after_refresh(vec![display_b, display_a]);
    bridge.refresh_displays().await.unwrap();

    assert_latest_scene(&engine, 3, "300");
    // The old primary was never configured under its own identity, so it is a
    // first-seen display and keeps showing the primary's wallpaper.
    assert_latest_scene(&engine, 1, "300");
}

#[tokio::test]
async fn clear_shader_cache_removes_cache_and_rebuilds_active_scenes() {
    let root = tempfile::tempdir().unwrap();
    let paths = BridgePaths::for_home(root.path());
    std::fs::create_dir_all(paths.shader_cache_root()).unwrap();
    std::fs::write(paths.shader_cache_root().join("stale-cache.bin"), [1, 2, 3]).unwrap();

    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(1)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_paths(paths.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    apply_primary_wallpaper(&bridge, "100").await;
    wait_for_reconcile_count(&engine, 1);

    assert_eq!(bridge.settings_snapshot().await.unwrap().storage.shader_cache_size_bytes, 3);
    std::fs::write(paths.shader_cache_root().join("new-cache.bin"), [4, 5]).unwrap();
    assert_eq!(bridge.settings_snapshot().await.unwrap().storage.shader_cache_size_bytes, 5,
        "an explicit settings read sees new files even within a snapshot burst");

    let snapshot = bridge.clear_shader_cache().await.unwrap();

    wait_for_reconcile_count(&engine, 2);
    assert!(paths.shader_cache_root().is_dir());
    assert!(!paths.shader_cache_root().join("stale-cache.bin").exists());
    assert_eq!(snapshot.storage.shader_cache_size_bytes, 0);
    assert_latest_scene(&engine, 1, "100");
    let calls = engine.calls();
    let refreshed_scene = calls
        .last()
        .expect("cache clear should reconcile scenes")
        .iter()
        .find(|scene| scene.display.display_id == 1)
        .expect("primary display should keep an active scene");
    assert!(
        refreshed_scene.force_shader_refresh,
        "cache clear must force active scenes to rebuild their shader cache"
    );
}

fn display_snapshot(display_id: u32) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc: DisplayDesc::with_identity(
            display_id,
            DisplayIdentity::default(),
            0,
            0,
            1920,
            1080,
            1.0,
        ),
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

async fn assert_display_enabled(bridge: &WallpaperBridge, display_id: &str, expected: bool) {
    let display = bridge
        .settings_snapshot()
        .await
        .unwrap()
        .displays
        .into_iter()
        .find(|display| display.display_id == display_id)
        .unwrap_or_else(|| panic!("missing display {display_id}"));
    assert_eq!(display.enabled, expected);
}

async fn settings_row_id_by_title(bridge: &WallpaperBridge, title_part: &str) -> String {
    bridge
        .settings_snapshot()
        .await
        .unwrap()
        .displays
        .into_iter()
        .find(|display| display.title.contains(title_part))
        .unwrap_or_else(|| panic!("missing display row containing title {title_part}"))
        .display_id
}

async fn settings_row(
    bridge: &WallpaperBridge,
    display_id: &str,
) -> crate::BridgeDisplaySettingsRow {
    bridge
        .settings_snapshot()
        .await
        .unwrap()
        .displays
        .into_iter()
        .find(|display| display.display_id == display_id)
        .unwrap_or_else(|| panic!("missing settings row for display {display_id}"))
}


/// One scene committed to a 120 Hz primary display and running. The engine
/// snapshot carries the descriptor the scene was opened with, and live
/// updates land in it as they do in the real engine.
async fn running_scene_bridge(engine: &FakeEngineFacade) -> (WallpaperBridge, tempfile::TempDir) {
    let display = identified_display("primary", 1);
    let primary = DisplaySnapshotEntry {
        desc: display.desc.clone().with_refresh_rate(120),
        ..display
    };
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    store
        .save_app_config(&AppConfig {
            monitors: vec![MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                mode: "independent".to_string(),
                wallpaper: Some("100".to_string()),
                mirror_target: None,
            }],
            ..AppConfig::default()
        })
        .unwrap();
    store
        .save_wallpaper(&WallpaperConfig::new_for("100", "scene"))
        .unwrap();
    engine.set_snapshot_after_refresh(vec![primary]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge.refresh_displays().await.unwrap();
    let opened = engine.calls()[0][0].clone();
    let running = vec![DisplaySnapshotEntry {
        identity: opened.display.identity.clone(),
        desc: opened.display.clone(),
        handle: Some(SceneHandle::new(1)),
        accepts_pointer_input: true,
        paused: false,
        window_active: true,
        assignment: Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&opened))),
    }];
    engine.set_snapshot(running.clone());
    engine.set_snapshot_after_refresh(running);
    (bridge, root)
}

async fn assert_refresh_keeps_the_scene(bridge: &WallpaperBridge, engine: &FakeEngineFacade) {
    let calls_before = engine.calls().len();
    bridge.refresh_displays().await.unwrap();
    assert_eq!(
        engine.calls().len(),
        calls_before,
        "nothing about the wallpaper changed, so a display refresh must not reload it"
    );
}

#[tokio::test]
async fn a_display_refresh_does_not_reload_a_scene_whose_audio_response_has_nothing_to_read() {
    // Audio response is on, but the scene has not reported reading audio, so
    // the system-audio tap stays shut for it. That is not a different wallpaper.
    let engine = FakeEngineFacade::default();
    engine.scenes_start_without_audio();
    let (bridge, _root) = running_scene_bridge(&engine).await;
    bridge
        .set_audio_response_enabled("100".into(), true)
        .await
        .unwrap();
    assert_eq!(
        engine.audio_capture_calls().last(),
        Some(&(SceneHandle::new(1), false))
    );

    assert_refresh_keeps_the_scene(&bridge, &engine).await;
}

#[tokio::test]
async fn a_display_refresh_does_not_reload_a_scene_held_to_the_battery_frame_rate() {
    let engine = FakeEngineFacade::default();
    let (bridge, _root) = running_scene_bridge(&engine).await;
    bridge
        .set_battery_mode(crate::BridgeBatteryMode::ReducedQuality)
        .await
        .unwrap();
    bridge
        .set_power_source_for_test(crate::power::PowerSource::Battery)
        .await;
    assert_eq!(engine.fps_calls().last(), Some(&(SceneHandle::new(1), 30)));

    assert_refresh_keeps_the_scene(&bridge, &engine).await;
}

#[tokio::test]
async fn a_display_refresh_does_not_reload_a_scene_held_to_the_quality_throttle() {
    let engine = FakeEngineFacade::default();
    let _release = EngineRelease::of(&engine);
    let (bridge, _root) = running_scene_bridge(&engine).await;
    bridge
        .set_quality_throttle(vec![crate::BridgeQualityThrottleCause::Heat])
        .await
        .unwrap();
    assert_eq!(engine.fps_calls().last(), Some(&(SceneHandle::new(1), 30)));

    assert_refresh_keeps_the_scene(&bridge, &engine).await;
}

#[tokio::test]
async fn a_display_refresh_does_not_reload_a_scene_muted_for_other_audio() {
    let engine = FakeEngineFacade::default();
    let (bridge, _root) = running_scene_bridge(&engine).await;
    bridge.set_audio_suppressed(true).await.unwrap();

    assert_refresh_keeps_the_scene(&bridge, &engine).await;
}

#[tokio::test]
async fn a_display_refresh_does_not_reload_a_scene_paused_by_a_lock_or_a_covered_display() {
    let engine = FakeEngineFacade::default();
    let (bridge, _root) = running_scene_bridge(&engine).await;
    bridge.set_presentation_suspended(true).await.unwrap();
    bridge
        .set_display_presentation_suspended("1".into(), true)
        .await
        .unwrap();

    assert_refresh_keeps_the_scene(&bridge, &engine).await;
}

#[tokio::test]
async fn a_display_refresh_does_not_reload_a_scene_held_to_the_frame_rate_cap() {
    // A 120 Hz display under a 60 fps cap: the scene runs at 60.
    let engine = FakeEngineFacade::default();
    let (bridge, _root) = running_scene_bridge(&engine).await;
    bridge.set_frame_rate_cap(Some(60)).await.unwrap();
    assert_eq!(engine.fps_calls().last(), Some(&(SceneHandle::new(1), 60)));

    assert_refresh_keeps_the_scene(&bridge, &engine).await;
}

#[tokio::test]
async fn a_reported_press_comes_back_out_of_the_bridge() {
    // The sink the bridge installs owns the only sender for its channel. A
    // facade that accepted it and dropped it closed that channel before the
    // first press, so every button in every wallpaper was dead from startup --
    // and it looked exactly like a button nobody had bound.
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![DisplaySnapshotEntry {
        handle: Some(SceneHandle::new(11)),
        accepts_pointer_input: true,
        paused: false,
        window_active: true,
        assignment: Some(WallpaperAssignment::Direct(
            SceneTemplate::builder("/workshop/content/431960/100/project.json")
                .build()
                .unwrap(),
        )),
        ..display_snapshot(7)
    }]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .set_display_config_enabled("100".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    bridge
        .set_media_integration_enabled("100".into(), true)
        .await
        .unwrap();
    assert_eq!(bridge.system_media_consent_handles().await.unwrap(), vec![11]);

    assert!(
        engine.report_user_shortcut(SceneHandle::new(11), "nextsongbutton", "media:next"),
        "the bridge never installed its sink, so nothing could report a press"
    );
    let event = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        bridge.next_user_shortcut(),
    )
    .await
    .expect("a reported press has to come back out rather than hang")
    .expect("the channel closed instead of delivering the press");
    assert_eq!(event.property, "nextsongbutton");
    assert_eq!(event.value, "media:next");
}

#[tokio::test]
async fn an_unbound_transport_shortcut_reaches_the_scene_engine() {
    // The scene engine parses the project file itself, where these ship empty,
    // so a default this host supplies is invisible to it unless it is sent
    // along with the user's overrides. Without that the button resolves to
    // nothing, `openUserShortcut` reports an empty value and the press is
    // dropped -- however the panel happens to show the binding.
    let root = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(1)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_project_for_test(
            "100",
            "Scene",
            r#"{
            "type":"scene",
            "title":"Scene",
            "general":{"properties":{
                "playpausebutton":{"type":"usershortcut","text":"Play","value":"","order":1},
                "nextsongbutton":{"type":"usershortcut","text":"Next","value":"","order":2},
                "secretbutton":{"type":"usershortcut","text":"Secret","value":"","order":3}
            }}
        }"#,
        )
        .await;
    bridge
        .set_display_config_enabled("100".to_string(), "1".to_string(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();

    // A name that says nothing stays out of it rather than being guessed at.
    assert_eq!(
        latest_scene(&engine, 1).property_override_json.as_deref(),
        Some(r#"{"nextsongbutton":"media:next","playpausebutton":"media:playpause"}"#)
    );

    // The user's own choice still wins, including choosing no action.
    bridge
        .edit_property(
            "100".to_string(),
            "nextsongbutton".to_string(),
            BridgePropertyValue::String {
                value: String::new(),
            },
        )
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("100".to_string(), true)
        .await
        .unwrap();
    assert_eq!(
        latest_scene(&engine, 1).property_override_json.as_deref(),
        Some(r#"{"nextsongbutton":"","playpausebutton":"media:playpause"}"#)
    );
}

async fn apply_primary_wallpaper(bridge: &WallpaperBridge, wallpaper_id: &str) {
    bridge
        .set_display_config_enabled(wallpaper_id.to_string(), "primary".to_string(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options(wallpaper_id.to_string(), true)
        .await
        .unwrap();
}

fn wait_for_reconcile_count(engine: &FakeEngineFacade, expected: usize) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    loop {
        let calls = engine.calls().len();
        if calls == expected {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "expected {expected} reconcile calls, got {calls}"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}

fn identified_display(uuid: &str, display_id: u32) -> DisplaySnapshotEntry {
    let identity = DisplayIdentity {
        uuid: Some(uuid.to_string()),
        vendor_id: Some(10),
        model_id: Some(display_id),
        serial_number: Some(100 + display_id),
        unit_number: Some(display_id),
        name: Some(format!("Display {uuid}")),
    };
    DisplaySnapshotEntry {
        identity: identity.clone(),
        desc: DisplayDesc::with_identity(display_id, identity, 0, 0, 1920, 1080, 2.0),
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

fn latest_scene(engine: &FakeEngineFacade, display_id: u32) -> wallpaper_core::project::SceneDesc {
    engine
        .calls()
        .last()
        .expect("reconcile call")
        .iter()
        .find(|scene| scene.display.display_id == display_id)
        .unwrap_or_else(|| panic!("missing scene for display {display_id}"))
        .clone()
}

fn assert_latest_scene(engine: &FakeEngineFacade, display_id: u32, workshop_id: &str) {
    let calls = engine.calls();
    let scenes = calls.last().expect("reconcile call");
    let scene = scenes
        .iter()
        .find(|scene| scene.display.display_id == display_id)
        .unwrap_or_else(|| panic!("missing scene for display {display_id}"));
    assert!(
        scene.scene_path.contains(&format!("/{workshop_id}/")),
        "display {display_id} should use wallpaper {workshop_id}, got {}",
        scene.scene_path
    );
}

#[tokio::test]
async fn verbose_logging_persists_across_relaunch_and_can_be_turned_off() {
    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    let bridge = BridgeBuilder::new(FakeEngineFacade::default())
        .with_config_store(store.clone())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    assert!(!bridge.settings_snapshot().await.unwrap().verbose_logging);

    let snapshot = bridge.set_verbose_logging(true).await.unwrap();
    assert!(snapshot.settings.verbose_logging);
    drop(bridge);

    let relaunched = BridgeBuilder::new(FakeEngineFacade::default())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    assert!(relaunched.settings_snapshot().await.unwrap().verbose_logging);

    let snapshot = relaunched.set_verbose_logging(false).await.unwrap();
    assert!(!snapshot.settings.verbose_logging);
    assert!(!store.load().unwrap().config.diagnostics.verbose_logging);
}

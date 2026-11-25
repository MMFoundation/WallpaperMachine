//! Per-wallpaper quality overrides (Phase 1: `render_scale` + `scene_quality`).
//!
//! Each wallpaper can override the global internal render scale and scene
//! quality independently. Per-wallpaper render scale applies live to the
//! displays showing that wallpaper without reparsing, never bypasses battery
//! or thermal throttling (`.min(...)`), and persists across restarts.

use std::fs;

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry,
    project::{PostProcessing, QualityLevel, SceneHandle, SceneQuality},
};

use crate::{
    BridgeBatteryMode, BridgeMsaa, BridgePostProcessing, BridgeQualityLevel,
    BridgeQualityThrottleCause, BridgeSceneQuality,
    api::{BridgeBuilder, WallpaperBridge},
    config::ConfigStore,
    engine::FakeEngineFacade,
    paths::BridgePaths,
    power::PowerSource,
};

fn display_with_scene(display_id: u32, handle: u64) -> DisplaySnapshotEntry {
    let desc =
        DisplayDesc::with_identity(display_id, DisplayIdentity::default(), 0, 0, 1920, 1080, 1.0)
            .with_refresh_rate(60);
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc,
        handle: Some(SceneHandle::new(handle)),
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

fn write_scene_project(paths: &BridgePaths, id: &str, title: &str) {
    let dir = paths.steam_workshop_root().join(id);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("project.json"),
        format!(r#"{{"type":"scene","title":"{title}","file":"scene.pkg","description":""}}"#),
    )
    .unwrap();
}

async fn two_scene_bridge(
    engine: &FakeEngineFacade,
    store: ConfigStore,
    paths: BridgePaths,
) -> WallpaperBridge {
    write_scene_project(&paths, "100", "Scene 100");
    write_scene_project(&paths, "200", "Scene 200");
    write_scene_project(&paths, "300", "Scene 300");
    engine.set_snapshot(vec![display_with_scene(7, 1), display_with_scene(9, 2)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_config_store(store)
        .with_paths(paths)
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .with_startup_power_source(PowerSource::External)
        .build()
        .unwrap();
    bridge.refresh_library().await.unwrap();
    for (id, display) in [("100", "7"), ("200", "9")] {
        bridge
            .set_display_config_enabled(id.into(), display.into(), true)
            .await
            .unwrap();
        bridge.apply_wallpaper_options(id.into(), true).await.unwrap();
    }
    bridge
}

#[tokio::test]
async fn per_wallpaper_render_scale_applies_live_and_never_bypasses_throttling() {
    let temp = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(temp.path().join("config"));
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    let engine = FakeEngineFacade::default();
    let bridge = two_scene_bridge(&engine, store.clone(), paths.clone()).await;

    let reconciles_before = engine.reconcile_call_count();
    let bundle = bridge
        .set_wallpaper_render_scale("100".into(), Some(0.5))
        .await
        .unwrap();
    assert_eq!(bundle.wallpaper_options.render_scale_override, Some(0.5));
    assert_eq!(
        engine.reconcile_call_count(),
        reconciles_before,
        "changing per-wallpaper render scale must not reconcile or reparse"
    );
    assert_eq!(
        engine.render_scale_calls(),
        vec![(SceneHandle::new(1), 0.5)],
        "only the display running wallpaper 100 receives the override"
    );

    // Battery reduced-quality profile (0.75) leaves 100 at 0.5 and lowers 200 to 0.75.
    bridge
        .set_battery_quality_profile(0.75, 30)
        .await
        .unwrap();
    bridge
        .set_battery_mode(BridgeBatteryMode::ReducedQuality)
        .await
        .unwrap();
    let before_battery = engine.render_scale_calls().len();
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    assert_eq!(
        engine.render_scale_calls()[before_battery..],
        [(SceneHandle::new(1), 0.5), (SceneHandle::new(2), 0.75)]
    );

    // Setting wallpaper 200 override to 1.0 under thermal/battery throttle stays clamped to 0.75.
    bridge
        .set_quality_throttle(vec![BridgeQualityThrottleCause::Heat])
        .await
        .unwrap();
    let before_override = engine.render_scale_calls().len();
    bridge
        .set_wallpaper_render_scale("200".into(), Some(1.0))
        .await
        .unwrap();
    assert_eq!(
        engine.render_scale_calls()[before_override..],
        [(SceneHandle::new(2), 0.75)],
        "per-wallpaper 1.0 override must never bypass battery or thermal throttling"
    );

    // Leaving battery while heat throttle remains still clamps wallpaper 200 to 0.75.
    let before_external = engine.render_scale_calls().len();
    bridge.set_power_source_for_test(PowerSource::External).await;
    assert_eq!(
        engine.render_scale_calls()[before_external..],
        [(SceneHandle::new(1), 0.5), (SceneHandle::new(2), 0.75)],
        "thermal throttle must continue clamping even on external power"
    );

    // Clearing thermal throttling hands back 100 -> 0.5, 200 -> 1.0.
    let before_unthrottle = engine.render_scale_calls().len();
    bridge.set_quality_throttle(vec![]).await.unwrap();
    assert_eq!(
        engine.render_scale_calls()[before_unthrottle..],
        [(SceneHandle::new(1), 0.5), (SceneHandle::new(2), 1.0)]
    );

    // Clearing 100's override returns it to global 1.0.
    let before_clear = engine.render_scale_calls().len();
    let cleared = bridge
        .set_wallpaper_render_scale("100".into(), None)
        .await
        .unwrap();
    assert_eq!(cleared.wallpaper_options.render_scale_override, None);
    assert_eq!(
        engine.render_scale_calls()[before_clear..],
        [(SceneHandle::new(1), 1.0)]
    );

    // Persisted override for 200 survives restart.
    assert_eq!(store.load_wallpaper("200").unwrap().render_scale, Some(1.0));
    drop(bridge);
    let restarted = BridgeBuilder::new(FakeEngineFacade::default())
        .with_config_store(store)
        .with_paths(paths)
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build()
        .unwrap();
    restarted.refresh_library().await.unwrap();
    assert_eq!(
        restarted
            .wallpaper_options_snapshot("200".into())
            .await
            .unwrap()
            .render_scale_override,
        Some(1.0)
    );
}

#[tokio::test]
async fn per_wallpaper_scene_quality_overrides_only_that_wallpaper_and_persists() {
    let temp = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(temp.path().join("config"));
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    let engine = FakeEngineFacade::default();
    let bridge = two_scene_bridge(&engine, store.clone(), paths.clone()).await;

    let low = BridgeSceneQuality {
        msaa: BridgeMsaa::Off,
        shadows: BridgeQualityLevel::Low,
        volumetrics: BridgeQualityLevel::Off,
        reflections: false,
        post_processing: BridgePostProcessing::Disabled,
    };

    let reconciles = engine.reconcile_call_count();
    let bundle = bridge
        .set_wallpaper_scene_quality("100".into(), Some(low))
        .await
        .unwrap();
    assert_eq!(bundle.wallpaper_options.scene_quality_override, Some(low));
    assert_eq!(engine.reconcile_call_count(), reconciles + 1);

    let scenes = engine.rendered_scenes();
    let scene_100 = scenes.iter().find(|s| s.display.display_id == 7).unwrap();
    let scene_200 = scenes.iter().find(|s| s.display.display_id == 9).unwrap();
    assert_eq!(
        scene_100.quality,
        SceneQuality {
            msaa: 0,
            shadows: QualityLevel::Low,
            volumetrics: QualityLevel::Off,
            reflection: false,
            post_processing: PostProcessing::Disabled,
        }
    );
    assert_eq!(
        scene_200.quality,
        SceneQuality::default(),
        "global default remains in force for wallpaper 200"
    );

    // Setting an override on an unassigned wallpaper persists without reconciling.
    let reconciles = engine.reconcile_call_count();
    bridge
        .set_wallpaper_scene_quality("300".into(), Some(low))
        .await
        .unwrap();
    assert_eq!(engine.reconcile_call_count(), reconciles);

    // Clearing 100's override reconciles it back to global default.
    let cleared = bridge
        .set_wallpaper_scene_quality("100".into(), None)
        .await
        .unwrap();
    assert_eq!(cleared.wallpaper_options.scene_quality_override, None);
    let scene_100_restored = engine
        .rendered_scenes()
        .into_iter()
        .find(|s| s.display.display_id == 7)
        .unwrap();
    assert_eq!(scene_100_restored.quality, SceneQuality::default());

    // Restart preserves unassigned 300's override.
    assert!(store.load_wallpaper("300").unwrap().scene_quality.is_some());
    drop(bridge);
    let restarted = BridgeBuilder::new(FakeEngineFacade::default())
        .with_config_store(store)
        .with_paths(paths)
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build()
        .unwrap();
    restarted.refresh_library().await.unwrap();
    assert_eq!(
        restarted
            .wallpaper_options_snapshot("300".into())
            .await
            .unwrap()
            .scene_quality_override,
        Some(low)
    );
}

#[tokio::test]
async fn web_wallpaper_descriptor_uses_per_wallpaper_render_scale_and_clamps_under_battery() {
    let temp = tempfile::tempdir().unwrap();
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    let web = paths.steam_workshop_root().join("500");
    fs::create_dir_all(&web).unwrap();
    fs::write(
        web.join("project.json"),
        r#"{"type":"web","title":"Web 500","file":"index.html"}"#,
    )
    .unwrap();
    fs::write(web.join("index.html"), "<html></html>").unwrap();

    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_with_scene(7, 1)]);
    let bridge = BridgeBuilder::new(engine)
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .with_startup_power_source(PowerSource::External)
        .build()
        .unwrap();
    bridge.refresh_library().await.unwrap();
    bridge
        .set_display_config_enabled("500".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("500".into(), true).await.unwrap();

    bridge
        .set_wallpaper_render_scale("500".into(), Some(0.5))
        .await
        .unwrap();
    assert_eq!(bridge.web_wallpapers().await.unwrap()[0].render_scale, 0.5);

    bridge
        .set_wallpaper_render_scale("500".into(), Some(1.0))
        .await
        .unwrap();
    bridge
        .set_battery_quality_profile(0.6, 30)
        .await
        .unwrap();
    bridge
        .set_battery_mode(BridgeBatteryMode::ReducedQuality)
        .await
        .unwrap();
    bridge.set_power_source_for_test(PowerSource::Battery).await;
    assert_eq!(
        bridge.web_wallpapers().await.unwrap()[0].render_scale,
        0.6,
        "web wallpaper override must clamp to the battery profile via .min()"
    );
}

#[tokio::test]
async fn preloaded_parked_scene_at_reduced_scale_restores_native_scale_after_override_clears() {
    let temp = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(temp.path().join("config"));
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    let engine = FakeEngineFacade::default();
    let bridge = two_scene_bridge(&engine, store, paths).await;

    // Give unassigned wallpaper 300 a reduced render scale and preload it on display 7 while
    // active wallpaper 100 on display 7 runs at native 1.0 scale.
    bridge
        .set_wallpaper_render_scale("300".into(), Some(0.5))
        .await
        .unwrap();
    bridge
        .preload_desktop_wallpaper(7, "300".into())
        .await
        .unwrap();

    // Clear 300's override before switching Spaces to 300.
    bridge
        .set_wallpaper_render_scale("300".into(), None)
        .await
        .unwrap();

    let before_switch = engine.render_scale_calls().len();
    bridge
        .set_display_config_enabled("300".into(), "7".into(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("300".into(), true)
        .await
        .unwrap();

    assert!(
        engine.render_scale_calls()[before_switch..]
            .contains(&(SceneHandle::new(1), 1.0)),
        "promoting a parked scene preloaded at reduced scale must restore native 1.0 scale after override clears"
    );
}

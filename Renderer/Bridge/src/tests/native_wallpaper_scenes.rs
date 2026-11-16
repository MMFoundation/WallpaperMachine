use std::{collections::BTreeMap, fs, path::Path};

use serde_json::{Value, json};
use wallpaper_core::{DisplaySelector, DisplaySnapshotEntry, WallpaperAssignment};

use super::fixture_values::{anonymous, identified};
use crate::{
    BridgeBatteryMode, BridgeEngineOptionId, BridgeErrorKind, BridgeFraming, BridgeLockScreenScene,
    BridgePropertyValue, BridgeScalingMode, WallpaperBridge,
    api::BridgeBuilder,
    config::{
        AppConfig, ConfigStore, FramingCfg, MonitorCfg, MonitorRender, SerializedSelector,
        WallpaperConfig,
    },
    display::DisplaySnapshotExt,
    engine::FakeEngineFacade,
    paths::BridgePaths,
    power::PowerSource,
};

const SCENE: &str = r#"{"type":"scene","title":"Scene","file":"scene.json",
    "general":{"properties":{"speed":{"type":"slider","value":1,"min":0,"max":10}}}}"#;
const VIDEO: &str = r#"{"type":"video","title":"Video","file":"clip.mp4",
    "general":{"properties":{"schemecolor":{"type":"color","value":"1 0 0"}}}}"#;
const WEB: &str = r#"{"type":"web","title":"Web","file":"index.html",
    "general":{"properties":{"speed":{"type":"slider","value":1,"min":0,"max":10}}}}"#;

struct Harness {
    bridge: WallpaperBridge,
    engine: FakeEngineFacade,
    store: ConfigStore,
    _home: tempfile::TempDir,
}

impl Harness {
    async fn new(
        config: AppConfig,
        displays: Vec<DisplaySnapshotEntry>,
        saved: Vec<WallpaperConfig>,
    ) -> Self {
        let home = tempfile::tempdir().unwrap();
        let paths = BridgePaths::for_home(home.path());
        let store = ConfigStore::open(home.path().join("config"));
        store.save_app_config(&config).unwrap();
        for wallpaper in saved {
            store.save_wallpaper(&wallpaper).unwrap();
        }
        for (id, manifest) in [
            ("scene", SCENE),
            ("video", VIDEO),
            ("web", WEB),
            ("desktop", SCENE),
            (
                "unsupported",
                r#"{"type":"application","title":"Application","file":"app.exe"}"#,
            ),
        ] {
            let project = paths.project_json(id);
            fs::create_dir_all(project.parent().unwrap()).unwrap();
            fs::write(project, manifest).unwrap();
        }
        let engine = FakeEngineFacade::default();
        engine.set_snapshot(displays);
        let bridge = BridgeBuilder::new(engine.clone())
            .with_config_store(store.clone())
            .with_paths(paths)
            .with_mouse_polling_enabled(false)
            .with_power_watching_enabled(false)
            .with_startup_power_source(PowerSource::External)
            .build()
            .unwrap();
        bridge.refresh_library().await.unwrap();
        Self {
            bridge,
            engine,
            store,
            _home: home,
        }
    }

    async fn export(&self, id: &str) -> Vec<BridgeLockScreenScene> {
        self.bridge
            .native_wallpaper_scenes(id.into())
            .await
            .unwrap()
    }
}

fn files(root: &Path) -> BTreeMap<std::path::PathBuf, Vec<u8>> {
    let mut result = BTreeMap::new();
    for entry in fs::read_dir(root).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            result.extend(files(&path));
        } else {
            result.insert(path.clone(), fs::read(path).unwrap());
        }
    }
    result
}

fn display(id: u32) -> DisplaySnapshotEntry {
    anonymous(id, 2.0, 120, false)
}

fn monitor(id: u32) -> MonitorCfg {
    MonitorCfg {
        selector: SerializedSelector::LiveDisplayId { display_id: id },
        ..MonitorCfg::default()
    }
}

#[tokio::test]
async fn exports_all_kinds_without_a_desktop_assignment_or_creating_configuration() {
    let h = Harness::new(
        AppConfig::default(),
        vec![display(7), display(8)],
        Vec::new(),
    )
    .await;
    let before = h.bridge.all_snapshots().await.unwrap();
    let saved = files(h.store.root());
    for id in ["scene", "video", "web"] {
        let rows = h.export(id).await;
        assert_eq!(
            rows.iter().map(|row| row.display_id).collect::<Vec<_>>(),
            [7, 8]
        );
        assert!(rows.iter().all(|row| row.wallpaper_id == id && !row.paused));
        assert!(
            rows.iter()
                .all(|row| Path::new(&row.project_path).is_absolute())
        );
        assert!(h.bridge.lock_screen_scenes().await.unwrap().is_empty());
    }
    assert_eq!(h.bridge.all_snapshots().await.unwrap(), before);
    assert_eq!(files(h.store.root()), saved);
    assert!(h.engine.rendered_scenes().is_empty());
    assert!(h.engine.calls().is_empty());
}

#[tokio::test]
async fn includes_only_connected_enabled_nonmirror_displays() {
    let mut live_mirror = display(12);
    live_mirror.assignment = Some(WallpaperAssignment::Mirror(DisplaySelector::Primary));
    let h = Harness::new(
        AppConfig {
            monitors: vec![
                MonitorCfg {
                    enabled: false,
                    ..MonitorCfg::default()
                },
                MonitorCfg {
                    enabled: false,
                    ..monitor(8)
                },
                MonitorCfg {
                    mode: "mirror".into(),
                    mirror_target: Some(SerializedSelector::Primary),
                    ..monitor(9)
                },
                monitor(10),
                monitor(99),
            ],
            ..AppConfig::default()
        },
        vec![
            display(7),
            display(8),
            display(9),
            display(10),
            display(11),
            live_mirror,
        ],
        Vec::new(),
    )
    .await;
    let before = files(h.store.root());
    for id in ["scene", "video", "web"] {
        assert_eq!(
            h.export(id)
                .await
                .iter()
                .map(|row| row.display_id)
                .collect::<Vec<_>>(),
            [10, 11]
        );
    }
    assert_eq!(files(h.store.root()), before);
    assert!(h.engine.calls().is_empty());
}

#[tokio::test]
async fn keeps_saved_display_exclusions_when_live_selectors_change() {
    let saved_display = identified("external", 8, 120);
    let mut reconnected = saved_display.clone();
    reconnected.desc.display_id = 18;
    reconnected.identity.name = Some("Renamed display".into());
    reconnected.desc.identity = reconnected.identity.clone();
    let h = Harness::new(
        AppConfig {
            monitors: vec![
                MonitorCfg {
                    enabled: false,
                    ..monitor(7)
                },
                MonitorCfg {
                    selector: saved_display.connected_selector(),
                    enabled: false,
                    ..MonitorCfg::default()
                },
            ],
            ..AppConfig::default()
        },
        vec![display(7), reconnected, display(9)],
        Vec::new(),
    )
    .await;
    assert_eq!(
        h.export("scene")
            .await
            .iter()
            .map(|row| row.display_id)
            .collect::<Vec<_>>(),
        [9]
    );
    assert!(h.engine.calls().is_empty());
}

#[tokio::test]
async fn uses_saved_options_properties_and_positions_instead_of_the_draft() {
    let mut saved = WallpaperConfig::new_for("scene", "scene");
    saved.property_overrides.insert("speed".into(), json!(3));
    saved.engine_options.flip_horizontal = true;
    saved.engine_options.playback_rate = 150.0;
    saved.monitors = vec![
        MonitorRender {
            selector: SerializedSelector::Primary,
            frame_rate: Some(45),
            scaling_mode: "fit".into(),
            scaling_factor: 1.25,
            framing: FramingCfg {
                pan_x: 0.2,
                pan_y: 0.8,
            },
            ..MonitorRender::default()
        },
        MonitorRender {
            selector: SerializedSelector::LiveDisplayId { display_id: 8 },
            frame_rate: Some(30),
            framing: FramingCfg {
                pan_x: 0.9,
                pan_y: 0.1,
            },
            ..MonitorRender::default()
        },
    ];
    let h = Harness::new(
        AppConfig::default(),
        vec![display(7), display(8)],
        vec![saved],
    )
    .await;
    let committed = h.export("scene").await;
    assert_eq!(committed[0].fps, 45);
    assert_eq!(committed[0].scaling_mode, BridgeScalingMode::Match);
    assert_eq!(committed[0].scaling_factor, 1.25);
    assert_eq!(
        committed[0].framing,
        BridgeFraming {
            pan_x: 0.2,
            pan_y: 0.8
        }
    );
    assert_eq!(committed[1].fps, 30);
    assert_eq!(
        committed[1].framing,
        BridgeFraming {
            pan_x: 0.9,
            pan_y: 0.1
        }
    );
    assert!(committed[0].scene_quality.is_some());
    assert!(
        committed[0]
            .engine_options
            .as_ref()
            .unwrap()
            .flip_horizontal
    );
    assert_eq!(
        committed[0].engine_options.as_ref().unwrap().playback_rate,
        150.0
    );
    let properties: Value =
        serde_json::from_str(committed[0].properties_json.as_deref().unwrap()).unwrap();
    assert_eq!(properties["speed"].as_f64(), Some(3.0));

    h.bridge.select_wallpaper("scene".into()).await.unwrap();
    h.bridge
        .edit_property(
            "scene".into(),
            "speed".into(),
            BridgePropertyValue::Number { value: 8.0 },
        )
        .await
        .unwrap();
    h.bridge
        .edit_engine_option(
            "scene".into(),
            BridgeEngineOptionId::FlipHorizontal,
            BridgePropertyValue::Bool { value: false },
        )
        .await
        .unwrap();
    h.bridge
        .edit_scaling_factor("scene".into(), "primary".into(), 1.75)
        .await
        .unwrap();
    h.bridge
        .set_display_config_enabled("scene".into(), "8".into(), true)
        .await
        .unwrap();
    let before = h.bridge.all_snapshots().await.unwrap();
    let options = h
        .bridge
        .wallpaper_options_snapshot("scene".into())
        .await
        .unwrap();
    let disk = files(h.store.root());
    assert!(options.dirty);
    assert_eq!(h.export("scene").await, committed);
    assert_eq!(h.bridge.all_snapshots().await.unwrap(), before);
    assert_eq!(
        h.bridge
            .wallpaper_options_snapshot("scene".into())
            .await
            .unwrap(),
        options
    );
    assert_eq!(files(h.store.root()), disk);
    assert!(h.engine.calls().is_empty());
}

#[tokio::test]
async fn video_and_web_exports_keep_their_saved_backend_options() {
    let mut video = WallpaperConfig::new_for("video", "video");
    video
        .property_overrides
        .insert("schemecolor".into(), json!("0 0.5 1"));
    video.engine_options.flip_horizontal = true;
    video.monitors.push(MonitorRender {
        framing: FramingCfg {
            pan_x: 0.1,
            pan_y: 0.9,
        },
        ..MonitorRender::default()
    });
    let mut web = WallpaperConfig::new_for("web", "web");
    web.property_overrides.insert("speed".into(), json!(4));
    let h = Harness::new(AppConfig::default(), vec![display(7)], vec![video, web]).await;
    let video = h.export("video").await.remove(0);
    assert!(video.engine_options.unwrap().flip_horizontal);
    assert!(video.scene_quality.is_none());
    assert_eq!(
        video.framing,
        BridgeFraming {
            pan_x: 0.1,
            pan_y: 0.9
        }
    );
    assert_eq!(
        video.border_color,
        Some(crate::BridgeRgb {
            red: 0.0,
            green: 0.5,
            blue: 1.0
        })
    );
    let committed = h.export("web").await;
    let web = &committed[0];
    assert!(web.engine_options.is_none());
    assert!(web.scene_quality.is_none());
    assert_eq!(web.scaling_mode, BridgeScalingMode::Fill);
    let properties: Value = serde_json::from_str(web.properties_json.as_deref().unwrap()).unwrap();
    assert_eq!(properties["speed"]["value"].as_f64(), Some(4.0));
    h.bridge.select_wallpaper("web".into()).await.unwrap();
    h.bridge
        .edit_property(
            "web".into(),
            "speed".into(),
            BridgePropertyValue::Number { value: 9.0 },
        )
        .await
        .unwrap();
    assert_eq!(h.export("web").await, committed);
}

#[tokio::test]
async fn leaves_desktop_selection_renderer_and_legacy_export_unchanged() {
    let h = Harness::new(
        AppConfig::default(),
        vec![display(7), display(8)],
        Vec::new(),
    )
    .await;
    h.bridge.select_wallpaper("desktop".into()).await.unwrap();
    h.bridge
        .set_display_config_enabled("desktop".into(), "primary".into(), true)
        .await
        .unwrap();
    h.bridge
        .apply_wallpaper_options("desktop".into(), true)
        .await
        .unwrap();
    let before = h.bridge.all_snapshots().await.unwrap();
    let desktop = h.engine.rendered_scenes();
    let calls = h.engine.calls();
    let legacy = h.bridge.lock_screen_scenes().await.unwrap();
    let disk = files(h.store.root());
    assert!(!desktop.is_empty());
    for id in ["scene", "video", "web"] {
        assert!(h.export(id).await.iter().all(|row| row.wallpaper_id == id));
        assert_eq!(h.bridge.lock_screen_scenes().await.unwrap(), legacy);
    }
    assert_eq!(h.bridge.all_snapshots().await.unwrap(), before);
    assert_eq!(h.engine.rendered_scenes(), desktop);
    assert_eq!(h.engine.calls(), calls);
    assert_eq!(files(h.store.root()), disk);
}

#[tokio::test]
async fn obeys_user_and_power_policy_without_desktop_suspension_or_first_frames() {
    let h = Harness::new(AppConfig::default(), vec![display(7)], Vec::new()).await;
    h.bridge.set_presentation_suspended(true).await.unwrap();
    h.bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();
    h.bridge.set_presentation_unloaded(true).await.unwrap();
    for id in ["scene", "video", "web"] {
        assert!(!h.export(id).await[0].paused);
    }
    h.bridge.pause_all().await.unwrap();
    assert!(h.export("scene").await[0].paused);
    h.bridge.play_all().await.unwrap();
    h.bridge
        .set_battery_mode(BridgeBatteryMode::Pause)
        .await
        .unwrap();
    h.bridge
        .set_power_source_for_test(PowerSource::Battery)
        .await;
    for id in ["scene", "video", "web"] {
        assert!(h.export(id).await[0].paused);
    }
    h.bridge.play_all().await.unwrap();
    assert!(!h.export("scene").await[0].paused);
    h.bridge.set_battery_quality_profile(0.5, 24).await.unwrap();
    h.bridge
        .set_battery_mode(BridgeBatteryMode::ReducedQuality)
        .await
        .unwrap();
    for id in ["scene", "video", "web"] {
        assert_eq!(h.export(id).await[0].fps, 24);
    }
    h.bridge.set_frame_rate_cap(Some(15)).await.unwrap();
    for id in ["scene", "video", "web"] {
        assert_eq!(h.export(id).await[0].fps, 15);
    }
}

#[tokio::test]
async fn rejects_unknown_unsupported_and_corrupt_inputs_without_fallback_or_repairs() {
    let h = Harness::new(AppConfig::default(), vec![display(7)], Vec::new()).await;
    let before = h.bridge.all_snapshots().await.unwrap();
    let disk = files(h.store.root());
    for id in ["missing", "unsupported", "", "../scene", "/scene"] {
        let error = h
            .bridge
            .native_wallpaper_scenes(id.into())
            .await
            .unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput, "{id}");
    }
    assert_eq!(files(h.store.root()), disk);
    let path = h.store.root().join("wallpapers/scene.json");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, b"not valid json").unwrap();
    let corrupt = files(h.store.root());
    for _ in 0..2 {
        assert_eq!(
            h.bridge
                .native_wallpaper_scenes("scene".into())
                .await
                .unwrap_err()
                .kind(),
            BridgeErrorKind::Config
        );
    }
    assert_eq!(files(h.store.root()), corrupt);
    assert_eq!(h.bridge.all_snapshots().await.unwrap(), before);
    assert!(h.engine.calls().is_empty());
}

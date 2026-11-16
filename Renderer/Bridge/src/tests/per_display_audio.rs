use super::{
    fixture_values::identified,
    live_scene_fixture::{bridge, foreign_scene, installed, live, showing},
};
use crate::{
    config::{
        AppConfig, ConfigStore, MonitorCfg, MonitorRender, SerializedSelector, WallpaperConfig,
    },
    engine::FakeEngineFacade,
};
use wallpaper_core::project::SceneHandle;

#[test]
fn immediate_display_audio_keeps_pending_edits_and_survives_cancel() {
    use crate::state::drafts::WallpaperOptionsDraft;
    let mut draft =
        WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("sound", "scene"));
    draft
        .set_scaling_factor(SerializedSelector::Primary, 1.75)
        .unwrap();
    let saved = draft
        .set_display_volume_immediate(SerializedSelector::Primary, 0.25, &[])
        .unwrap();
    assert_eq!(saved.monitors[0].scaling_factor, 1.0);
    assert_eq!(saved.monitors[0].volume, Some(0.25));
    assert_eq!(draft.current().monitors[0].scaling_factor, 1.75);
    assert!(draft.is_dirty(&[]));
    let _ = draft.set_display_muted_immediate(SerializedSelector::Primary, true, &[]);
    draft.cancel();
    assert_eq!(draft.current().monitors[0].volume, Some(0.25));
    assert_eq!(draft.current().monitors[0].muted, Some(true));
    assert_eq!(draft.current().monitors[0].scaling_factor, 1.0);
    assert!(!draft.requires_reconcile(&[]));
    assert!(!draft.is_dirty(&[]));
}

#[test]
fn older_monitor_settings_inherit_audio_and_write_without_new_fields() {
    let config: WallpaperConfig = serde_json::from_str(
        r#"{
        "workshop_id":"sound", "type":"scene", "audio":{"volume":0.4,"muted":true},
        "monitors":[{"selector":{"kind":"primary"},"scaling_mode":"fill","scaling_factor":1}]
    }"#,
    )
    .unwrap();
    let audio = config.audio.for_display(config.monitors.first());
    assert_eq!((audio.volume, audio.muted), (0.4, true));
    let json = serde_json::to_value(&config).unwrap();
    assert!(json["monitors"][0].get("volume").is_none());
    assert!(json["monitors"][0].get("muted").is_none());
    assert_eq!(
        serde_json::from_value::<WallpaperConfig>(json).unwrap(),
        config
    );
}

fn fixture(
    config: WallpaperConfig,
) -> (FakeEngineFacade, super::live_scene_fixture::Fixture, String) {
    let engine = FakeEngineFacade::default();
    let left = identified("left", 1, 60);
    let right = identified("right", 2, 60);
    let mirror = identified("mirror", 3, 60);
    let right_selector = SerializedSelector::from_selector(
        &wallpaper_core::DisplaySelector::Identity(right.identity.clone()),
    );
    let mirror_selector = SerializedSelector::from_selector(
        &wallpaper_core::DisplaySelector::Identity(mirror.identity.clone()),
    );
    let snapshots = [&left, &right, &mirror]
        .into_iter()
        .map(|display| {
            live(
                display.clone(),
                u64::from(display.desc.display_id) + 10,
                &foreign_scene(display, "sound"),
                false,
            )
        })
        .collect();
    engine.set_snapshot(snapshots);
    let app = AppConfig {
        monitors: vec![
            showing(SerializedSelector::Primary, "sound"),
            showing(right_selector.clone(), "sound"),
            MonitorCfg {
                selector: mirror_selector,
                mode: "mirror".into(),
                mirror_target: Some(SerializedSelector::Primary),
                ..MonitorCfg::default()
            },
        ],
        ..AppConfig::default()
    };
    let fixture = bridge(&engine, installed(app, vec![("sound", Some(config))]), true);
    (engine, fixture, right_selector.id())
}

#[tokio::test]
async fn display_audio_edits_stay_local_and_survive_config_reload() {
    let mut config = WallpaperConfig::new_for("sound", "scene");
    config.audio.volume = 0.8;
    let (engine, fixture, right) = fixture(config);
    fixture
        .bridge
        .set_display_volume("sound".into(), "primary".into(), 0.25)
        .await
        .unwrap();
    let result = fixture
        .bridge
        .set_display_muted("sound".into(), "primary".into(), true)
        .await
        .unwrap();
    let options = result.wallpaper_options;
    assert_eq!(options.volume, 0.8);
    assert!(
        !options.muted,
        "display edits must not change the wallpaper's defaults"
    );
    let left = options
        .display_configurations
        .iter()
        .find(|row| row.display_id == "primary")
        .unwrap();
    let other = options
        .display_configurations
        .iter()
        .find(|row| row.display_id == right)
        .unwrap();
    assert_eq!((left.volume, left.muted), (0.25, true));
    assert_eq!((other.volume, other.muted), (0.8, false));
    assert_eq!(
        engine.audio_volume_calls(),
        vec![(SceneHandle::new(11), 0.25)]
    );
    assert_eq!(
        engine.audio_muted_calls(),
        vec![(SceneHandle::new(11), true)]
    );
    let loaded = ConfigStore::open(fixture.home.path().join("support"))
        .load_wallpaper("sound")
        .unwrap();
    let (_, reloaded, _) = self::fixture(loaded);
    let options = reloaded
        .bridge
        .wallpaper_options_snapshot("sound".into())
        .await
        .unwrap();
    let left = options
        .display_configurations
        .iter()
        .find(|row| row.display_id == "primary")
        .unwrap();
    assert_eq!((left.volume, left.muted), (0.25, true));
}

#[tokio::test]
async fn wallpaper_defaults_and_transient_audio_keep_display_overrides() {
    let config = WallpaperConfig::new_for("sound", "scene");
    let (engine, fixture, _) = fixture(config);
    fixture
        .bridge
        .set_display_volume("sound".into(), "primary".into(), 0.25)
        .await
        .unwrap();
    fixture
        .bridge
        .set_display_muted("sound".into(), "primary".into(), false)
        .await
        .unwrap();
    fixture
        .bridge
        .set_volume("sound".into(), 0.6)
        .await
        .unwrap();
    fixture
        .bridge
        .set_muted("sound".into(), true)
        .await
        .unwrap();
    let volumes = engine.audio_volume_calls();
    assert!(volumes.contains(&(SceneHandle::new(11), 0.25)));
    assert_eq!(volumes.last(), Some(&(SceneHandle::new(12), 0.6)));
    let muted = engine.audio_muted_calls();
    assert!(muted.contains(&(SceneHandle::new(11), false)));
    assert_eq!(muted.last(), Some(&(SceneHandle::new(12), true)));
    assert!(
        !volumes.iter().any(|(handle, _)| handle.raw() == 13),
        "a mirror keeps its own settings"
    );
    fixture.bridge.set_audio_gain(0.5).await.unwrap();
    let volumes = engine.audio_volume_calls();
    assert!(volumes.contains(&(SceneHandle::new(11), 0.125)));
    assert!(volumes.contains(&(SceneHandle::new(12), 0.3)));
    fixture.bridge.set_audio_suppressed(true).await.unwrap();
    fixture.bridge.set_audio_suppressed(false).await.unwrap();
    let muted = engine.audio_muted_calls();
    assert_eq!(
        &muted[muted.len() - 3..],
        &[
            (SceneHandle::new(11), false),
            (SceneHandle::new(12), true),
            (SceneHandle::new(13), false)
        ]
    );
}

#[tokio::test]
async fn invalid_display_audio_edits_do_not_save_or_touch_a_scene() {
    let (engine, fixture, _) = fixture(WallpaperConfig::new_for("sound", "scene"));
    for volume in [-0.1, 1.1, f32::NAN, f32::INFINITY] {
        assert!(
            fixture
                .bridge
                .set_display_volume("sound".into(), "primary".into(), volume)
                .await
                .is_err()
        );
    }
    assert!(
        fixture
            .bridge
            .set_display_volume("sound".into(), "missing".into(), 0.5)
            .await
            .is_err()
    );
    assert!(
        fixture
            .bridge
            .set_display_muted("missing".into(), "primary".into(), true)
            .await
            .is_err()
    );
    assert!(
        fixture
            .bridge
            .set_display_muted("sound".into(), "missing".into(), true)
            .await
            .is_err()
    );
    assert!(engine.audio_volume_calls().is_empty());
    assert!(engine.audio_muted_calls().is_empty());
    assert!(
        !fixture
            .home
            .path()
            .join("support/wallpapers/sound.json")
            .exists()
    );
}

#[tokio::test]
async fn an_audio_edit_through_a_display_alias_preserves_its_picture_settings() {
    let left = identified("left", 1, 60);
    let selector = SerializedSelector::from_selector(&wallpaper_core::DisplaySelector::Identity(
        left.identity,
    ));
    let mut config = WallpaperConfig::new_for("sound", "scene");
    config.monitors.push(MonitorRender {
        selector,
        scaling_mode: "fit".into(),
        scaling_factor: 1.7,
        frame_rate: Some(24),
        ..MonitorRender::default()
    });
    let (_, fixture, _) = fixture(config);
    let result = fixture
        .bridge
        .set_display_muted("sound".into(), "primary".into(), true)
        .await
        .unwrap();
    let row = result
        .wallpaper_options
        .display_configurations
        .into_iter()
        .find(|row| row.display_id == "primary")
        .unwrap();
    assert_eq!(
        (row.scaling_factor, row.target_fps, row.muted),
        (1.7, 24, true)
    );
    assert_eq!(row.scaling_mode, crate::api::BridgeScalingMode::Match);
}

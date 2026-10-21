use super::fixture_values::anonymous;

use crate::{
    api::BridgeBuilder,
    config::{AppConfig, ConfigStore, MonitorCfg, SerializedSelector, WallpaperConfig},
    engine::FakeEngineFacade,
    paths::BridgePaths,
};

#[tokio::test]
async fn wallpaper_missing_from_scanned_library_does_not_block_other_displays() {
    // Deleted while its display was disconnected: the assignment outlives the
    // files. The engine must not be handed it, or every reconcile fails.
    let home = tempfile::tempdir().unwrap();
    let paths = BridgePaths::for_home(home.path());
    let installed = paths.steam_workshop_root().join("100");
    std::fs::create_dir_all(&installed).unwrap();
    std::fs::write(
        installed.join("project.json"),
        r#"{"type":"scene","title":"Scene 100","file":"scene.json"}"#,
    )
    .unwrap();

    let root = tempfile::tempdir().unwrap();
    let store = ConfigStore::open(root.path().to_path_buf());
    let mut config = AppConfig::default();
    for (display_id, wallpaper) in [(7, "100"), (8, "gone")] {
        config.monitors.push(MonitorCfg {
            selector: SerializedSelector::LiveDisplayId { display_id },
            enabled: true,
            mode: "independent".to_string(),
            wallpaper: Some(wallpaper.to_string()),
            mirror_target: None,
        });
        store
            .save_wallpaper(&WallpaperConfig::new_for(wallpaper, "scene"))
            .unwrap();
    }
    store.save_app_config(&config).unwrap();

    let engine = FakeEngineFacade::default();
    engine.set_snapshot_after_refresh(vec![anonymous(7, 1.0, 60, true), anonymous(8, 1.0, 60, true)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .with_paths(paths)
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");

    bridge.bootstrap().await.unwrap();

    assert_eq!(
        bridge.app_snapshot().await.unwrap().active_wallpaper_ids,
        vec!["100".to_string()]
    );
    let calls = engine.calls();
    assert_eq!(calls.len(), 1);
    let displays: Vec<u32> = calls[0].iter().map(|scene| scene.display.display_id).collect();
    assert_eq!(displays, vec![7]);
}


use std::time::{Duration, Instant};

use wallpaper_core::project::SceneDesc;

use crate::engine::FakeEngineFacade;
use crate::{BridgeDisplaySettingsRow, WallpaperBridge};

pub(super) fn assert_owner(scenes: &[SceneDesc], display_id: u32, wallpaper_id: &str) {
    let scene = scenes
        .iter()
        .find(|scene| scene.display.display_id == display_id)
        .unwrap_or_else(|| panic!("No scene recorded for display {display_id}"));
    assert!(
        scene.scene_path.split('/').any(|part| part == wallpaper_id),
        "Display {display_id} has scene path {:?}, without wallpaper component {wallpaper_id:?}",
        scene.scene_path,
    );
}

pub(super) fn last_scene(engine: &FakeEngineFacade, display_id: u32) -> SceneDesc {
    engine
        .calls()
        .pop()
        .expect("No reconcile batch has been recorded")
        .into_iter()
        .find(|scene| scene.display.display_id == display_id)
        .unwrap_or_else(|| panic!("Latest reconcile batch has no scene for display {display_id}"))
}

pub(super) fn expect_last_owner(
    engine: &FakeEngineFacade,
    display_id: u32,
    wallpaper_id: &str,
) {
    let scene = last_scene(engine, display_id);
    assert_owner(std::slice::from_ref(&scene), display_id, wallpaper_id);
}

pub(super) async fn settings_row(
    bridge: &WallpaperBridge,
    display_id: &str,
) -> BridgeDisplaySettingsRow {
    bridge
        .settings_snapshot()
        .await
        .expect("Could not observe display settings")
        .displays
        .into_iter()
        .find(|row| row.display_id == display_id)
        .unwrap_or_else(|| panic!("Settings snapshot has no display {display_id:?}"))
}

pub(super) async fn settings_key(bridge: &WallpaperBridge, title_part: &str) -> String {
    bridge
        .settings_snapshot()
        .await
        .expect("Could not observe display settings")
        .displays
        .into_iter()
        .find(|row| row.title.contains(title_part))
        .unwrap_or_else(|| panic!("Settings snapshot has no title containing {title_part:?}"))
        .display_id
}

pub(super) async fn expect_enabled(
    bridge: &WallpaperBridge,
    display_id: &str,
    expected: bool,
) {
    let row = settings_row(bridge, display_id).await;
    assert_eq!(
        row.enabled, expected,
        "Unexpected enabled state for display {display_id:?}",
    );
}

pub(super) async fn enable_primary_apply(bridge: &WallpaperBridge, wallpaper_id: &str) {
    bridge
        .set_display_config_enabled(wallpaper_id.to_owned(), "primary".to_owned(), true)
        .await
        .expect("Could not enable the primary display configuration");
    bridge
        .apply_wallpaper_options(wallpaper_id.to_owned(), true)
        .await
        .expect("Could not apply wallpaper options");
}

pub(super) async fn wait_reconciles(
    engine: &FakeEngineFacade,
    expected: usize,
    bound: Duration,
) -> bool {
    let started = Instant::now();
    loop {
        if engine.reconcile_call_count() == expected {
            return true;
        }
        let elapsed = started.elapsed();
        if elapsed >= bound {
            return false;
        }
        tokio::time::sleep((bound - elapsed).min(Duration::from_millis(1))).await;
    }
}

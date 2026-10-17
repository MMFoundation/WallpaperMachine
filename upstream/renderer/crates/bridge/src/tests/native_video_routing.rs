//! Routing of plain local videos to the native player.
//!
//! The property that matters is exclusivity. A wallpaper belongs to exactly one
//! renderer at a time: if the native backend takes it, the scene engine must
//! not also be given a scene for it, or the display decodes and presents the
//! same content twice. The second property is that the fallback terminates —
//! a wallpaper the host refuses goes back to the engine and stays there.

use std::fs;

use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySnapshotEntry};

use crate::{api::BridgeBuilder, engine::FakeEngineFacade, paths::BridgePaths};

fn display_snapshot(display_id: u32) -> DisplaySnapshotEntry {
    let desc =
        DisplayDesc::with_identity(display_id, DisplayIdentity::default(), 0, 0, 1920, 1080, 1.0)
            .with_refresh_rate(60);
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc,
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: false,
        assignment: None,
    }
}

/// A workshop tree with two video projects whose media files exist (300 and
/// 500), and one whose declared media file does not (400).
fn workshop_with_videos(paths: &BridgePaths) {
    for (id, write_media) in [("300", true), ("400", false), ("500", true)] {
        let dir = paths.steam_workshop_root().join(id);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("project.json"),
            format!(
                r#"{{"type":"video","title":"Clip {id}","file":"clip.mp4","description":""}}"#
            ),
        )
        .unwrap();
        if write_media {
            fs::write(dir.join("clip.mp4"), b"not really a video, only its presence matters")
                .unwrap();
        }
    }
}

async fn video_bridge(
    engine: &FakeEngineFacade,
    temp: &tempfile::TempDir,
) -> crate::api::WallpaperBridge {
    engine.set_snapshot(vec![display_snapshot(7)]);
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    workshop_with_videos(&paths);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap();
    bridge
}

async fn commit(bridge: &crate::api::WallpaperBridge, wallpaper: &str, display: &str) {
    // The project model is what the routing reads: the wallpaper config alone
    // says nothing about the project's type or its media file.
    bridge
        .inject_scene_project_for_test(
            wallpaper,
            "Clip",
            &format!(
                r#"{{"type":"video","title":"Clip {wallpaper}","file":"clip.mp4","description":""}}"#
            ),
        )
        .await;
    bridge
        .inject_scene_wallpaper_config_for_test(wallpaper, "Video")
        .await;
    bridge
        .set_display_config_enabled(wallpaper.into(), display.into(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options(wallpaper.into(), true)
        .await
        .unwrap();
}

fn scene_ids(engine: &FakeEngineFacade) -> Vec<String> {
    engine
        .rendered_scenes()
        .iter()
        .map(|scene| scene.scene_path.clone())
        .collect()
}

/// The admission key the host would judge, read out of the descriptor the
/// bridge offered — exactly what a real host has to echo back when it refuses.
async fn admission_key(bridge: &crate::api::WallpaperBridge, wallpaper: &str) -> u64 {
    bridge
        .native_video_wallpapers()
        .await
        .unwrap()
        .into_iter()
        .find(|row| row.wallpaper_id == wallpaper)
        .expect("the wallpaper has to be offered natively before it can be refused")
        .admission_key
}

async fn is_offered_natively(bridge: &crate::api::WallpaperBridge, wallpaper: &str) -> bool {
    bridge
        .native_video_wallpapers()
        .await
        .unwrap()
        .iter()
        .any(|row| row.wallpaper_id == wallpaper)
}

fn scenes_for(engine: &FakeEngineFacade, wallpaper: &str) -> usize {
    scene_ids(engine)
        .iter()
        .filter(|path| path.contains(wallpaper))
        .count()
}

/// Scenes the engine currently renders for this wallpaper on one display.
/// A display with zero of these and no native descriptor has no backend at all.
fn scenes_on(engine: &FakeEngineFacade, wallpaper: &str, display_id: u32) -> usize {
    engine
        .rendered_scenes()
        .iter()
        .filter(|scene| {
            scene.display.display_id == display_id && scene.scene_path.contains(wallpaper)
        })
        .count()
}

/// The admission key for one display's slot. Two displays showing the same
/// clip at different target rates have different keys.
async fn admission_key_on(
    bridge: &crate::api::WallpaperBridge,
    wallpaper: &str,
    display_id: u32,
) -> u64 {
    bridge
        .native_video_wallpapers()
        .await
        .unwrap()
        .into_iter()
        .find(|row| row.wallpaper_id == wallpaper && row.display_id == display_id)
        .expect("the slot has to be offered natively before it can be refused")
        .admission_key
}

async fn native_display_ids(bridge: &crate::api::WallpaperBridge, wallpaper: &str) -> Vec<u32> {
    let mut ids: Vec<u32> = bridge
        .native_video_wallpapers()
        .await
        .unwrap()
        .iter()
        .filter(|row| row.wallpaper_id == wallpaper)
        .map(|row| row.display_id)
        .collect();
    ids.sort_unstable();
    ids
}

/// Two different clips on two displays, so the two slots have two distinct
/// admission keys. The key identifies a file; two displays showing the same file
/// share one.
async fn two_display_bridge(
    engine: &FakeEngineFacade,
    temp: &tempfile::TempDir,
) -> crate::api::WallpaperBridge {
    engine.set_snapshot(vec![display_snapshot(7), display_snapshot(9)]);
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    workshop_with_videos(&paths);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap();
    commit(&bridge, "300", "7").await;
    commit(&bridge, "500", "9").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();
    bridge
}

/// Replaces a clip's media file, keeping its path, so the bytes behind the
/// admission key change.
fn replace_media(temp: &tempfile::TempDir, wallpaper: &str) {
    let media = BridgePaths::for_home(temp.path().to_path_buf())
        .steam_workshop_root()
        .join(wallpaper)
        .join("clip.mp4");
    fs::write(&media, b"a different clip entirely, with a different length").unwrap();
}

/// Retargets the display's frame rate and commits it, which is the user action
/// that changes a wallpaper's admission key.
async fn retarget_fps(bridge: &crate::api::WallpaperBridge, wallpaper: &str, display: &str, fps: u32) {
    bridge
        .set_target_fps(wallpaper.into(), display.into(), fps)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options(wallpaper.into(), true)
        .await
        .unwrap();
}

#[tokio::test]
async fn a_plain_video_is_routed_natively_by_default() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;

    assert!(
        bridge
            .native_video_wallpapers()
            .await
            .unwrap()
            .iter()
            .any(|row| row.wallpaper_id == "300"),
        "native video is the default, so a fresh install offers the clip to the platform player"
    );
    assert!(
        !scene_ids(&engine).iter().any(|path| path.contains("300")),
        "a natively routed clip is not also handed to the scene engine"
    );
}

#[tokio::test]
async fn choosing_compatibility_keeps_the_wallpaper_in_the_scene_engine() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    bridge.set_native_video_backend_enabled(false).await.unwrap();

    assert!(
        bridge.native_video_wallpapers().await.unwrap().is_empty(),
        "nothing may be routed natively once the user chose Compatibility"
    );
    assert!(
        scene_ids(&engine).iter().any(|path| path.contains("300")),
        "the scene engine keeps the wallpaper while the backend is off"
    );
}

#[tokio::test]
async fn a_natively_routed_wallpaper_is_not_also_given_to_the_scene_engine() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;

    bridge.set_native_video_backend_enabled(true).await.unwrap();

    let native = bridge.native_video_wallpapers().await.unwrap();
    assert_eq!(native.len(), 1);
    assert_eq!(native[0].wallpaper_id, "300");
    assert_eq!(native[0].display_id, 7);
    assert!(native[0].media_path.ends_with("clip.mp4"));
    assert!(
        !scene_ids(&engine).iter().any(|path| path.contains("300")),
        "two renderers for one display would decode and present the same clip twice"
    );
}

#[tokio::test]
async fn a_video_whose_media_is_missing_stays_on_the_scene_engine() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "400", "7").await;

    bridge.set_native_video_backend_enabled(true).await.unwrap();

    assert!(
        bridge.native_video_wallpapers().await.unwrap().is_empty(),
        "a window that can never play is worse than the engine's own error path"
    );
    assert!(scene_ids(&engine).iter().any(|path| path.contains("400")));
}

#[tokio::test]
async fn a_refused_wallpaper_goes_back_to_the_engine_and_stays_there() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();
    assert_eq!(bridge.native_video_wallpapers().await.unwrap().len(), 1);

    let key = admission_key(&bridge, "300").await;
    bridge
        .reject_native_video(
            "300".into(),
            key,
            "target frame rate below the clip's rate".into(),
        )
        .await
        .unwrap();

    assert!(
        bridge.native_video_wallpapers().await.unwrap().is_empty(),
        "a refusal must take effect immediately, not on the next unrelated reconcile"
    );
    assert!(
        scene_ids(&engine).iter().any(|path| path.contains("300")),
        "the engine has to take it back or the display shows nothing"
    );

    // Repeating the refusal is not a second fallback: without this the host and
    // the bridge could hand the wallpaper back and forth indefinitely.
    let reconciles_before = engine.calls().len();
    bridge
        .reject_native_video(
            "300".into(),
            key,
            "target frame rate below the clip's rate".into(),
        )
        .await
        .unwrap();
    assert_eq!(engine.calls().len(), reconciles_before);
    assert!(bridge.native_video_wallpapers().await.unwrap().is_empty());
}

#[tokio::test]
async fn turning_the_backend_off_returns_every_wallpaper_and_clears_refusals() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();
    let key = admission_key(&bridge, "300").await;
    bridge
        .reject_native_video("300".into(), key, "unsupported".into())
        .await
        .unwrap();

    bridge.set_native_video_backend_enabled(false).await.unwrap();
    assert!(bridge.native_video_wallpapers().await.unwrap().is_empty());
    assert!(scene_ids(&engine).iter().any(|path| path.contains("300")));

    // A refusal describes a configuration the user has since changed, so it
    // must not permanently exclude the wallpaper from a later opt-in.
    bridge.set_native_video_backend_enabled(true).await.unwrap();
    assert_eq!(bridge.native_video_wallpapers().await.unwrap().len(), 1);
}

#[tokio::test]
async fn the_native_descriptor_carries_the_users_own_settings() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();

    bridge.set_volume("300".into(), 0.25).await.unwrap();
    bridge.set_muted("300".into(), true).await.unwrap();
    bridge.apply_wallpaper_options("300".into(), true).await.unwrap();

    let native = bridge.native_video_wallpapers().await.unwrap();
    assert_eq!(native.len(), 1);
    assert!((native[0].volume - 0.25).abs() < f32::EPSILON);
    assert!(native[0].muted);
}

#[tokio::test]
async fn hiding_a_display_pauses_only_its_native_wallpaper() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display_snapshot(7), display_snapshot(9)]);
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    workshop_with_videos(&paths);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap();
    commit(&bridge, "300", "7").await;
    commit(&bridge, "300", "9").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();

    bridge
        .set_display_presentation_suspended("9".into(), true)
        .await
        .unwrap();

    let native = bridge.native_video_wallpapers().await.unwrap();
    let hidden = native.iter().find(|row| row.display_id == 9).unwrap();
    let visible = native.iter().find(|row| row.display_id == 7).unwrap();
    assert!(hidden.paused);
    assert!(
        !visible.paused,
        "one screen being covered must not stop a screen that is still visible"
    );
}

#[tokio::test]
async fn a_refusal_holds_whatever_the_target_rate_is() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();

    // The host cannot decode the file, so the wallpaper goes back to the engine.
    let key = admission_key(&bridge, "300").await;
    bridge
        .reject_native_video("300".into(), key, "the player cannot decode it".into())
        .await
        .unwrap();
    assert!(!is_offered_natively(&bridge, "300").await);

    // Nothing about the refused file changed, so asking again must not hand it
    // back: that is the loop the fallback exists to terminate. A frame rate says
    // nothing about the file, so retargeting is not a change either.
    for fps in [30, 60, 24] {
        retarget_fps(&bridge, "300", "7", fps).await;
        assert!(
            !is_offered_natively(&bridge, "300").await,
            "a refusal about the file must keep holding at {fps} fps"
        );
        assert_eq!(scenes_for(&engine, "300"), 1, "the engine keeps playing it, once");
    }
}

#[tokio::test]
async fn the_target_rate_is_not_part_of_the_admission_key() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();
    retarget_fps(&bridge, "300", "7", 60).await;
    let at_60 = admission_key(&bridge, "300").await;

    // The player plays a clip at its own rate, so no target rate decides whether
    // it may take one, and a clip it took stays with it at every target.
    retarget_fps(&bridge, "300", "7", 24).await;
    assert_eq!(
        admission_key(&bridge, "300").await,
        at_60,
        "the key identifies the file, so a new target rate must not change it"
    );
    assert!(is_offered_natively(&bridge, "300").await);
    assert_eq!(scenes_for(&engine, "300"), 0);
}

#[tokio::test]
async fn replacing_the_media_file_at_the_same_path_re_offers_the_wallpaper() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();
    let key = admission_key(&bridge, "300").await;
    bridge
        .reject_native_video("300".into(), key, "codec the player cannot decode".into())
        .await
        .unwrap();
    assert!(!is_offered_natively(&bridge, "300").await);

    // The user replaces the clip, keeping the file name. The path is the same,
    // so a refusal recorded against the path alone would condemn a file the
    // host has never seen.
    let media = BridgePaths::for_home(temp.path().to_path_buf())
        .steam_workshop_root()
        .join("300")
        .join("clip.mp4");
    fs::write(&media, b"a different clip entirely, with a different length").unwrap();

    assert!(
        is_offered_natively(&bridge, "300").await,
        "the bytes behind the path changed, so the refusal describes nothing that still exists"
    );
    assert_eq!(
        scenes_for(&engine, "300"),
        0,
        "the engine has to let go the moment the native player takes it back"
    );
}

#[tokio::test]
async fn a_refusal_carrying_a_stale_admission_key_is_dropped() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();
    let stale_key = admission_key(&bridge, "300").await;

    // The user replaces the clip while the host is still deciding about the old
    // one, then the host's refusal for the old file lands.
    replace_media(&temp, "300");
    let reconciles_before = engine.calls().len();
    bridge
        .reject_native_video("300".into(), stale_key, "cannot decode the old file".into())
        .await
        .unwrap();

    assert!(
        is_offered_natively(&bridge, "300").await,
        "a refusal that lost a race with the user must not kill the configuration that replaced it"
    );
    assert_eq!(
        engine.calls().len(),
        reconciles_before,
        "a dropped refusal changes no routing, so it must not move the engine"
    );
    assert_eq!(scenes_for(&engine, "300"), 0);
}

#[tokio::test]
async fn exactly_one_backend_renders_a_wallpaper_across_a_refusal() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = video_bridge(&engine, &temp).await;
    commit(&bridge, "300", "7").await;
    bridge.set_native_video_backend_enabled(true).await.unwrap();

    assert!(is_offered_natively(&bridge, "300").await);
    assert_eq!(
        scenes_for(&engine, "300"),
        0,
        "a natively routed wallpaper must get no scene at all"
    );

    let key = admission_key(&bridge, "300").await;
    bridge
        .reject_native_video("300".into(), key, "unsupported".into())
        .await
        .unwrap();

    assert!(!is_offered_natively(&bridge, "300").await);
    assert_eq!(
        scenes_for(&engine, "300"),
        1,
        "a refused wallpaper must get exactly one scene, not one per refusal"
    );
}

#[tokio::test]
async fn refusing_one_display_leaves_the_other_on_the_native_player() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine, &temp).await;

    let key_7 = admission_key_on(&bridge, "300", 7).await;
    let key_9 = admission_key_on(&bridge, "500", 9).await;
    assert_ne!(key_7, key_9, "two files are two separate admission decisions");

    bridge
        .reject_native_video("300".into(), key_7, "the player cannot decode it".into())
        .await
        .unwrap();

    assert_eq!(
        native_display_ids(&bridge, "500").await,
        vec![9],
        "refusing one display must not take the clip off the display that accepted it"
    );
    assert!(native_display_ids(&bridge, "300").await.is_empty());
    assert_eq!(scenes_on(&engine, "300", 7), 1, "the refused display falls back");
    assert_eq!(
        scenes_on(&engine, "500", 9),
        0,
        "the display still on the native player must not also get a scene"
    );
}

#[tokio::test]
async fn refusing_both_displays_leaves_neither_without_a_backend() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine, &temp).await;

    let key_7 = admission_key_on(&bridge, "300", 7).await;
    let key_9 = admission_key_on(&bridge, "500", 9).await;
    bridge
        .reject_native_video("300".into(), key_7, "unsupported clip 300".into())
        .await
        .unwrap();
    bridge
        .reject_native_video("500".into(), key_9, "unsupported clip 500".into())
        .await
        .unwrap();

    // The second refusal must not overwrite the first. If it does, display 7's
    // record looks stale, gets pruned, and the clip is offered natively again
    // to a host that already refused that exact key — the host opens nothing
    // and activation has excluded the display as natively routed, so display 7
    // shows nothing at all.
    assert!(
        native_display_ids(&bridge, "300").await.is_empty()
            && native_display_ids(&bridge, "500").await.is_empty(),
        "both refusals stand; neither may be erased by the other"
    );
    assert_eq!(
        scenes_on(&engine, "300", 7),
        1,
        "display 7 must have exactly one backend, and it is the engine"
    );
    assert_eq!(
        scenes_on(&engine, "500", 9),
        1,
        "display 9 must have exactly one backend, and it is the engine"
    );
}

#[tokio::test]
async fn replacing_one_refused_displays_clip_re_offers_only_that_display() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = two_display_bridge(&engine, &temp).await;

    let key_7 = admission_key_on(&bridge, "300", 7).await;
    let key_9 = admission_key_on(&bridge, "500", 9).await;
    bridge
        .reject_native_video("300".into(), key_7, "unsupported clip 300".into())
        .await
        .unwrap();
    bridge
        .reject_native_video("500".into(), key_9, "unsupported clip 500".into())
        .await
        .unwrap();
    assert!(native_display_ids(&bridge, "500").await.is_empty());

    // Display 9's file is replaced; display 7's is not.
    replace_media(&temp, "500");

    assert_eq!(
        native_display_ids(&bridge, "500").await,
        vec![9],
        "only the display whose file changed is offered again"
    );
    assert_eq!(
        scenes_on(&engine, "300", 7),
        1,
        "the display nobody touched stays refused and stays on the engine"
    );
    assert_eq!(scenes_on(&engine, "500", 9), 0);
}

/// Display 7 plays the clip; display 9 mirrors it at `mirror_fps`.
///
/// A mirror has no scene of its own — [`ActivationInputs::build`] only ever
/// gives it a copy of the source's — so the pair has to be admitted or refused
/// together, at whichever target is stricter.
async fn mirror_group_bridge(
    engine: &FakeEngineFacade,
    temp: &tempfile::TempDir,
    source_fps: u32,
    mirror_fps: u32,
) -> crate::api::WallpaperBridge {
    engine.set_snapshot(vec![display_snapshot(7), display_snapshot(9)]);
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    workshop_with_videos(&paths);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .with_paths(paths)
        .build()
        .unwrap();
    commit(&bridge, "300", "7").await;
    bridge
        .set_display_mode("9".into(), crate::api::BridgeDisplayMode::Mirror)
        .await
        .unwrap();
    bridge.set_mirror_target("9".into(), "7".into()).await.unwrap();
    bridge.set_mirror_target_fps("9".into(), mirror_fps).await.unwrap();
    bridge.set_native_video_backend_enabled(true).await.unwrap();
    retarget_fps(&bridge, "300", "7", source_fps).await;
    bridge
}

fn native_row(
    rows: &[crate::api::BridgeNativeVideoWallpaper],
    display_id: u32,
) -> &crate::api::BridgeNativeVideoWallpaper {
    rows.iter()
        .find(|row| row.display_id == display_id)
        .expect("display must be offered natively")
}

#[tokio::test]
async fn a_mirror_shares_its_sources_key_and_carries_no_rate() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = mirror_group_bridge(&engine, &temp, 60, 30).await;

    let rows = bridge.native_video_wallpapers().await.unwrap();
    let source = native_row(&rows, 7).clone();
    let mirror = native_row(&rows, 9);

    assert_eq!(
        source.admission_key, mirror.admission_key,
        "one verdict has to cover the group, so the group needs one key"
    );
    // No member's target rate takes part in the key.
    bridge.set_mirror_target_fps("9".into(), 24).await.unwrap();
    retarget_fps(&bridge, "300", "7", 30).await;
    assert_eq!(admission_key_on(&bridge, "300", 7).await, source.admission_key);
}

#[tokio::test]
async fn refusing_a_mirror_group_returns_every_member_to_the_engine() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = mirror_group_bridge(&engine, &temp, 60, 30).await;
    let key = admission_key_on(&bridge, "300", 7).await;

    bridge
        .reject_native_video("300".into(), key, "30 is below the clip's rate".into())
        .await
        .unwrap();

    assert!(
        native_display_ids(&bridge, "300").await.is_empty(),
        "the whole group leaves the native player, not just the display that was judged"
    );
    assert_eq!(
        scenes_on(&engine, "300", 7),
        1,
        "the source falls back to the engine"
    );
    assert_eq!(
        scenes_on(&engine, "300", 9),
        1,
        "and the mirror gets its copy, or it is left with no backend at all"
    );
}

#[tokio::test]
async fn a_mirror_group_stays_native_whatever_its_members_targets() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = mirror_group_bridge(&engine, &temp, 60, 30).await;

    assert_eq!(
        native_display_ids(&bridge, "300").await,
        vec![7, 9],
        "a clip plays at its own rate, so a stricter mirror does not take the group off the player"
    );
    assert_eq!(scenes_on(&engine, "300", 7), 0);
    assert_eq!(scenes_on(&engine, "300", 9), 0);
}

#[tokio::test]
async fn a_mirrors_target_never_re_evaluates_a_refused_group() {
    let temp = tempfile::tempdir().unwrap();
    let engine = FakeEngineFacade::default();
    let bridge = mirror_group_bridge(&engine, &temp, 60, 30).await;
    let refused_key = admission_key_on(&bridge, "300", 7).await;
    bridge
        .reject_native_video("300".into(), refused_key, "the player cannot decode it".into())
        .await
        .unwrap();
    assert!(native_display_ids(&bridge, "300").await.is_empty());

    // The refusal is about the file, which a target rate does not touch, so the
    // group stays where the host's verdict put it.
    bridge.set_mirror_target_fps("9".into(), 60).await.unwrap();

    assert!(
        native_display_ids(&bridge, "300").await.is_empty(),
        "a new mirror target is not a new decision about the file"
    );
    assert_eq!(scenes_on(&engine, "300", 7), 1);
    assert_eq!(scenes_on(&engine, "300", 9), 1);
}


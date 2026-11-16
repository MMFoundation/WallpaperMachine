use super::*;

fn report_audio(f: &Fixture, handle: SceneHandle) {
    f.engine.require_audio(handle, true);
    f.handle()
        .blocking_ask(AudioRequirementChanged {
            handles: vec![handle],
        })
        .unwrap();
}

fn assert_audio_active(f: &Fixture, handle: SceneHandle) {
    let controls = f.engine.live_scene_controls(handle).unwrap();
    assert!(
        controls.audio_response_enabled,
        "the published scene must react to audio"
    );
    assert!(
        controls.audio_capture_enabled,
        "the published scene must retain capture ownership"
    );
    assert!(
        !f.engine.audio_capture_demand().suspended,
        "publishing an audio consumer must clear the previous selection's capture suspension"
    );
}

#[tokio::test]
async fn audio_sync_preserves_other_displays_and_demand_after_registration_failure() {
    let f = Fixture::new(
        AppConfig::default(),
        vec![empty_row(1, 60), empty_row(2, 60)],
    );
    f.select(A);
    f.enable_draft(A, "primary", true);
    f.enable_draft(A, "2", true);
    f.successful_apply(A, &[(1, 5911), (2, 5912)]);
    let failed = SceneHandle::new(5911);
    let healthy = SceneHandle::new(5912);
    assert!(f.engine.audio_capture_demand().suspended);
    f.engine.require_audio(failed, true);
    f.engine.require_audio(healthy, true);
    f.engine.fail_selected_setter(
        SelectedSetter::AudioCapture,
        failed,
        1,
        FaultTiming::BeforeMutation,
        EngineError::Render("capture registration refused".into()),
    );

    let error = f
        .handle()
        .blocking_ask(AudioRequirementChanged {
            handles: vec![failed, healthy],
        })
        .unwrap_err();

    assert_error(
        error,
        BridgeErrorKind::Engine,
        &engine_boundary("capture registration refused"),
    );
    assert_eq!(f.engine.audio_capture_state(failed), Some(false));
    assert_audio_active(&f, healthy);
    f.close().await;
}

#[tokio::test]
async fn apply_starts_capture_when_audio_requirement_precedes_the_first_frame() {
    let f = Fixture::new(AppConfig::default(), vec![empty_row(1, 60)]);
    f.select(A);
    f.enable_draft(A, "primary", true);
    let handle = SceneHandle::new(5901);
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, handle.raw())]));
    let pending = f.start_apply(A, true);
    entered(gate).release();
    wait_live(&f.engine, &[handle]);
    report_audio(&f, handle);
    assert!(f.engine.audio_capture_demand().suspended);
    pending.finish(&f.engine, &[handle]).unwrap();
    assert_audio_active(&f, handle);
    f.close().await;
}

#[tokio::test]
async fn apply_repairs_capture_lost_between_worker_registration_and_response() {
    let f = Fixture::new(AppConfig::default(), vec![empty_row(1, 60)]);
    f.select(A);
    f.enable_draft(A, "primary", true);
    let handle = SceneHandle::new(5913);
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, handle.raw())]));
    let mut response = f.engine.hold_next_audio_response();
    let pending = f.start_apply(A, true);
    entered(gate).release();
    wait_live(&f.engine, &[handle]);
    f.engine.require_audio(handle, true);
    let deadline = Instant::now() + DEADLINE;
    loop {
        f.engine.emit_first_frame(handle);
        match response.entered.try_recv() {
            Ok(()) => break,
            Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {
                assert!(
                    Instant::now() < deadline,
                    "worker did not reach its response write"
                );
                thread::sleep(QUANTUM);
            }
            Err(error) => panic!("response barrier closed: {error}"),
        }
    }
    assert_eq!(f.engine.audio_capture_state(handle), Some(true));
    report_audio(&f, handle);
    assert_eq!(f.engine.audio_capture_state(handle), Some(false));
    assert!(
        !f.engine
            .live_scene_controls(handle)
            .unwrap()
            .audio_response_enabled
    );
    response.release.send(()).unwrap();
    pending.finish(&f.engine, &[handle]).unwrap();
    assert!(
        f.engine
            .live_scene_controls(handle)
            .unwrap()
            .audio_response_enabled
    );
    assert_audio_active(&f, handle);
    f.close().await;
}

#[tokio::test]
async fn apply_restores_capture_when_audio_report_overwrites_worker_registration() {
    let mut app = AppConfig::default();
    app.quality.render_scale = 0.5;
    let f = Fixture::new(app, vec![empty_row(1, 60)]);
    f.select(A);
    f.enable_draft(A, "primary", true);
    let handle = SceneHandle::new(5902);
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, handle.raw())]));
    let terminal = f.engine.hold_next_render_scale_completion(handle);
    let pending = f.start_apply(A, true);
    entered(gate).release();
    wait_live(&f.engine, &[handle]);
    f.engine.require_audio(handle, true);
    let terminal = completed_render_scale(terminal, &f.engine, &[handle]);
    assert_eq!(f.engine.audio_capture_state(handle), Some(true));
    report_audio(&f, handle);
    assert_eq!(f.engine.audio_capture_state(handle), Some(false));
    terminal.release();
    pending.finish(&f.engine, &[handle]).unwrap();
    assert_audio_active(&f, handle);
    f.close().await;
}

#[tokio::test]
async fn apply_save_failure_keeps_capture_aligned_with_the_published_desktop() {
    let f = Fixture::new(AppConfig::default(), vec![empty_row(1, 60)]);
    f.select(A);
    f.enable_draft(A, "primary", true);
    let obstruction = SaveObstruction::new(&f, false);
    let expected = f.store.save_app_config(&AppConfig::default()).unwrap_err();
    let handle = SceneHandle::new(5903);
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, handle.raw())]));
    let pending = f.start_apply(A, true);
    entered(gate).release();
    wait_live(&f.engine, &[handle]);
    report_audio(&f, handle);
    assert_eq!(
        error_pair(&pending.finish(&f.engine, &[handle]).unwrap_err()),
        error_pair(&expected)
    );
    assert_audio_active(&f, handle);
    assert_eq!(f.snapshots().app.active_wallpaper_ids, vec![A.to_owned()]);
    drop(obstruction);
    f.close().await;
}

#[tokio::test]
async fn display_publication_starts_and_stops_capture_with_its_audio_consumer() {
    let mut app = configured();
    let mut secondary = assignment(connected(2), Some(B));
    secondary.enabled = false;
    app.monitors.push(secondary);
    let f = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 60)]);
    let primary = SceneHandle::new(5904);
    let audio = SceneHandle::new(5905);
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, primary.raw()), result(2, audio.raw())]));
    let actor = f.handle();
    let pending = request(move || {
        actor.blocking_ask(SetDisplayEnabled {
            display_id: "2".into(),
            enabled: true,
        })
    });
    entered(gate).release();
    wait_live(&f.engine, &[primary, audio]);
    report_audio(&f, audio);
    assert!(f.engine.audio_capture_demand().suspended);
    pending.finish(&f.engine, &[primary, audio]).unwrap();
    assert_audio_active(&f, audio);

    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, primary.raw())]));
    let actor = f.handle();
    let pending = request(move || {
        actor.blocking_ask(SetDisplayEnabled {
            display_id: "2".into(),
            enabled: false,
        })
    });
    entered(gate).release();
    pending.finish(&f.engine, &[primary]).unwrap();
    assert!(f.engine.audio_capture_demand().suspended);
    assert_eq!(f.engine.audio_capture_state(audio), None);
    f.close().await;
}

#[tokio::test]
async fn stale_apply_repair_restores_capture_for_the_committed_selection() {
    let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
    f.handle()
        .blocking_ask(AudioRequirementChanged { handles: vec![] })
        .unwrap();
    assert!(f.engine.audio_capture_demand().suspended);
    f.select(B);
    f.enable_draft(B, "primary", true);
    let stale = SceneHandle::new(5906);
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, stale.raw())]));
    let pending = f.start_apply(B, true);
    entered(gate).release();
    wait_live(&f.engine, &[stale]);
    f.engine.require_audio(stale, true);
    f.edit(B, 0.7);
    let repaired = SceneHandle::new(5907);
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, repaired.raw())]));
    pending.finish(&f.engine, &[stale]).unwrap();
    let repair = entered(gate);
    assert_eq!(
        repair.scenes[0].scene_path,
        f.paths.project_json(A).to_string_lossy()
    );
    repair.release();
    wait_live(&f.engine, &[repaired]);
    f.engine.require_audio(repaired, true);
    f.engine.emit_first_frame(repaired);
    f.repairs_idle();
    assert_audio_active(&f, repaired);
    assert_eq!(f.snapshots().app.active_wallpaper_ids, vec![A.to_owned()]);
    assert_eq!(f.engine.audio_capture_state(stale), None);
    f.close().await;
}

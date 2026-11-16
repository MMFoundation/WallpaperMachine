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

fn audio_operation_entered(mut control: OperationControl) -> tokio::sync::oneshot::Sender<()> {
    let deadline = Instant::now() + DEADLINE;
    loop {
        match control.entered.try_recv() {
            Ok(()) => return control.release,
            Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {
                assert!(Instant::now() < deadline, "audio operation did not enter");
                thread::sleep(QUANTUM);
            }
            Err(error) => panic!("audio operation barrier closed: {error}"),
        }
    }
}

#[tokio::test]
async fn failed_audio_rollback_save_restores_live_state_and_reports_both_errors() {
    for response_failure in [false, true] {
        let f = Fixture::new(configured(), vec![empty_row(1, 60)]);
        let handle = SceneHandle::new(5920);
        f.select(A);
        f.edit(A, 0.3);
        f.successful_apply(A, &[(1, handle.raw())]);
        report_audio(&f, handle);
        f.handle()
            .blocking_ask(SetAudioResponseEnabled {
                wallpaper_id: A.into(),
                enabled: false,
            })
            .unwrap();
        let gate = if response_failure {
            f.engine.hold_next_audio_response()
        } else {
            f.engine
                .hold_next_demand(Err(EngineError::Render("activation refused".into())))
        };
        let actor = f.handle();
        let toggle = request(move || {
            actor.blocking_ask(SetAudioResponseEnabled {
                wallpaper_id: A.into(),
                enabled: true,
            })
        });
        let release = audio_operation_entered(gate);
        if response_failure {
            f.engine.fail_selected_setter(
                SelectedSetter::AudioResponse,
                handle,
                1,
                FaultTiming::BeforeMutation,
                EngineError::Render("activation refused".into()),
            );
        }
        let optimistic = f.wallpaper_bytes(A);
        assert!(
            serde_json::from_slice::<WallpaperConfig>(&optimistic)
                .unwrap()
                .audio
                .response_enabled
        );
        let obstruction = SaveObstruction::new(&f, true);
        let save_error = f
            .store
            .save_wallpaper(&WallpaperConfig::new_for(A, "scene"))
            .unwrap_err();
        release.send(()).unwrap();
        let error = toggle.finish(&f.engine, &[]).unwrap_err();

        assert!(
            !f.engine
                .live_scene_controls(handle)
                .unwrap()
                .audio_response_enabled
        );
        assert_eq!(f.engine.audio_capture_state(handle), Some(false));
        assert!(f.engine.audio_capture_demand().suspended);
        assert!(
            !f.snapshots()
                .wallpaper_options
                .unwrap()
                .audio_response_enabled
        );
        report_audio(&f, handle);
        assert!(
            !f.engine
                .live_scene_controls(handle)
                .unwrap()
                .audio_response_enabled
        );
        assert_eq!(f.engine.audio_capture_state(handle), Some(false));
        assert!(f.engine.audio_capture_demand().suspended);
        assert_eq!(error.kind(), BridgeErrorKind::Engine);
        assert!(error.message().contains("activation refused"));
        assert!(error.message().contains(save_error.message()));
        drop(obstruction);
        assert_eq!(f.wallpaper_bytes(A), optimistic);
        f.handle()
            .blocking_ask(SetAudioResponseEnabled {
                wallpaper_id: A.into(),
                enabled: false,
            })
            .unwrap();
        assert!(
            !serde_json::from_slice::<WallpaperConfig>(&f.wallpaper_bytes(A))
                .unwrap()
                .audio
                .response_enabled
        );
        f.close().await;
    }
}

#[tokio::test]
async fn failed_audio_rollback_save_keeps_a_fresh_failed_apply_disabled() {
    let mut app = configured();
    app.quality.render_scale = 0.5;
    let f = Fixture::new(app, vec![empty_row(1, 60)]);
    let handle = SceneHandle::new(5921);
    f.select(A);
    f.edit(A, 0.3);
    f.successful_apply(A, &[(1, handle.raw())]);
    report_audio(&f, handle);
    f.handle()
        .blocking_ask(SetAudioResponseEnabled {
            wallpaper_id: A.into(),
            enabled: false,
        })
        .unwrap();
    let gate = f
        .engine
        .hold_next_demand(Err(EngineError::Render("activation refused".into())));
    let actor = f.handle();
    let toggle = request(move || {
        actor.blocking_ask(SetAudioResponseEnabled {
            wallpaper_id: A.into(),
            enabled: true,
        })
    });
    let release = audio_operation_entered(gate);
    let obstruction = SaveObstruction::new(&f, true);
    release.send(()).unwrap();
    toggle.finish(&f.engine, &[]).unwrap_err();
    assert!(
        !f.snapshots()
            .wallpaper_options
            .unwrap()
            .audio_response_enabled
    );

    f.edit(A, 0.7);
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, handle.raw())]));
    let terminal = f.engine.hold_next_render_scale_completion(handle);
    let apply = f.start_apply(A, true);
    let reconcile = entered(gate);
    assert!(!reconcile.scenes[0].audio_response_enabled);
    reconcile.release();
    let terminal = completed_render_scale(terminal, &f.engine, &[handle]);
    assert!(
        !f.engine
            .live_scene_controls(handle)
            .unwrap()
            .audio_response_enabled
    );
    report_audio(&f, handle);
    terminal.release();
    apply.finish(&f.engine, &[handle]).unwrap_err();
    assert!(
        !f.engine
            .live_scene_controls(handle)
            .unwrap()
            .audio_response_enabled
    );
    assert_eq!(f.engine.audio_capture_state(handle), Some(false));
    assert!(f.engine.audio_capture_demand().suspended);
    drop(obstruction);
    f.close().await;
}

#[tokio::test]
async fn failed_audio_rollback_save_invalidates_an_apply_prepared_during_the_toggle() {
    let mut app = configured();
    app.quality.render_scale = 0.5;
    let f = Fixture::new(app, vec![empty_row(1, 60)]);
    let original = SceneHandle::new(5922);
    f.select(A);
    f.edit(A, 0.3);
    f.successful_apply(A, &[(1, original.raw())]);
    report_audio(&f, original);
    f.handle()
        .blocking_ask(SetAudioResponseEnabled {
            wallpaper_id: A.into(),
            enabled: false,
        })
        .unwrap();
    f.edit(A, 0.7);
    let response = f.engine.hold_next_audio_response();
    let actor = f.handle();
    let toggle = request(move || {
        actor.blocking_ask(SetAudioResponseEnabled {
            wallpaper_id: A.into(),
            enabled: true,
        })
    });
    let response = audio_operation_entered(response);
    let stale = original;
    let gate = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, stale.raw())]));
    let apply = f.start_apply(A, true);
    let reconcile = entered(gate);
    assert!(reconcile.scenes[0].audio_response_enabled);
    let terminal = f.engine.hold_next_render_scale_completion(stale);
    reconcile.release();
    wait_live(&f.engine, &[stale]);
    f.engine.require_audio(stale, true);
    let terminal = completed_render_scale(terminal, &f.engine, &[stale]);
    let demand = f
        .engine
        .hold_next_demand(Err(EngineError::Render("activation refused".into())));
    response.send(()).unwrap();
    let demand = audio_operation_entered(demand);
    let obstruction = SaveObstruction::new(&f, true);
    demand.send(()).unwrap();
    toggle.finish(&f.engine, &[]).unwrap_err();

    let repaired = SceneHandle::new(5924);
    let repair = f
        .engine
        .hold_next_reconcile(Ok(vec![result(1, repaired.raw())]));
    terminal.release();
    apply.finish(&f.engine, &[stale]).unwrap();
    let repair = entered(repair);
    assert!(!repair.scenes[0].audio_response_enabled);
    repair.release();
    wait_live(&f.engine, &[repaired]);
    f.engine.require_audio(repaired, true);
    f.engine.emit_first_frame(repaired);
    f.repairs_idle();
    assert!(
        !f.engine
            .live_scene_controls(repaired)
            .unwrap()
            .audio_response_enabled
    );
    assert_eq!(f.engine.audio_capture_state(repaired), Some(false));
    assert!(f.engine.audio_capture_demand().suspended);
    assert!(
        !f.snapshots()
            .wallpaper_options
            .unwrap()
            .audio_response_enabled
    );
    drop(obstruction);
    f.close().await;
}

#[tokio::test]
async fn failed_audio_rollback_save_does_not_skip_other_handles_or_demand_on_cleanup_errors() {
    let mut app = configured();
    app.monitors.push(assignment(connected(2), Some(A)));
    let f = Fixture::new(app, vec![empty_row(1, 60), empty_row(2, 60)]);
    let failed = SceneHandle::new(5925);
    let healthy = SceneHandle::new(5926);
    f.select(A);
    f.edit(A, 0.3);
    f.successful_apply(A, &[(1, failed.raw()), (2, healthy.raw())]);
    report_audio(&f, failed);
    report_audio(&f, healthy);
    f.handle()
        .blocking_ask(SetAudioResponseEnabled {
            wallpaper_id: A.into(),
            enabled: false,
        })
        .unwrap();
    let demand = f
        .engine
        .hold_next_demand(Err(EngineError::Render("activation refused".into())));
    let actor = f.handle();
    let toggle = request(move || {
        actor.blocking_ask(SetAudioResponseEnabled {
            wallpaper_id: A.into(),
            enabled: true,
        })
    });
    let demand = audio_operation_entered(demand);
    let obstruction = SaveObstruction::new(&f, true);
    let save_error = f
        .store
        .save_wallpaper(&WallpaperConfig::new_for(A, "scene"))
        .unwrap_err();
    f.engine.fail_selected_setter(
        SelectedSetter::AudioCapture,
        failed,
        1,
        FaultTiming::BeforeMutation,
        EngineError::Render("registration rollback refused".into()),
    );
    let rollback_demand = f
        .engine
        .hold_next_demand(Err(EngineError::Render("demand rollback refused".into())));
    demand.send(()).unwrap();
    audio_operation_entered(rollback_demand).send(()).unwrap();
    let error = toggle.finish(&f.engine, &[]).unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::Engine);
    for cause in [
        "activation refused",
        save_error.message(),
        "registration rollback refused",
        "demand rollback refused",
    ] {
        assert!(error.message().contains(cause), "missing failure: {cause}");
    }
    assert!(
        !f.engine
            .live_scene_controls(healthy)
            .unwrap()
            .audio_response_enabled
    );
    assert_eq!(f.engine.audio_capture_state(healthy), Some(false));
    report_audio(&f, failed);
    assert!(
        !f.engine
            .live_scene_controls(failed)
            .unwrap()
            .audio_response_enabled
    );
    assert_eq!(f.engine.audio_capture_state(failed), Some(false));
    assert!(f.engine.audio_capture_demand().suspended);
    drop(obstruction);
    f.close().await;
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

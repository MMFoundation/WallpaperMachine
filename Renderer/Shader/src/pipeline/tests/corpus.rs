// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The whole pipeline (preprocess, legalize, translate to Metal, reflect) over Wallpaper
//! Engine's shipped shaders, and over workshop shaders unpacked under
//! `artifacts/p5/workshop-shaders/<id>/shaders/` (third-party test input, never committed).
//! Each test skips with a printed reason when its input is absent (spec D test 33).
//!
//! The sweep prints its pass rate; run it with `--nocapture` to see it:
//! `cargo test --release --lib pipeline::tests::corpus -- --nocapture`.

use std::collections::BTreeMap;
use std::fs;

use crate::dialect::tests::corpus::{Layered, cause, combo_sets, pairs, present_textures, shader_files, shaders_root, workshop_root};
use crate::names::{SlotName, classify_slot_name};
use crate::pipeline::{CompiledProgram, compile};
use crate::request::{ShaderRequest, Stage, StageKind};

#[derive(Default)]
struct Sweep {
    ok: usize,
    failures: BTreeMap<String, Vec<String>>,
    /// Binding names a host that finds resources by name would refuse, with the programs.
    refused_names: BTreeMap<String, Vec<String>>,
    micros: Vec<u128>,
}

/// The names the host binds (spec D 2.4): the block, a material texture and its sampler, the
/// chroma plane of a video slot and its sampler.
fn in_vocabulary(name: &str) -> bool {
    if name == "GlobalUniforms" {
        return true;
    }
    let texture = |n: &str| matches!(classify_slot_name(n), SlotName::Canonical(_));
    if texture(name) {
        return true;
    }
    if let Some(rest) = name.strip_prefix("_we_Sampler_") {
        return texture(rest) || rest.strip_prefix("_we_VideoChroma").is_some_and(|d| !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()));
    }
    name.strip_prefix("_we_VideoChroma").is_some_and(|d| !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()))
}

fn is_stub(text: &str) -> bool {
    let code: String = text.lines().filter(|l| !l.trim_start().starts_with('#')).collect::<Vec<_>>().join(" ");
    code.split_whitespace().collect::<Vec<_>>().join(" ") == "void main() { }"
}

fn sweep(files: &[(String, StageKind, String)], includes: &Layered, skip: impl Fn(&str) -> bool, plane_slots: &[u8]) -> Sweep {
    let mut s = Sweep::default();
    for (set_name, combos) in combo_sets() {
        for (name, vertex, fragment) in pairs(files) {
            // A pair with a missing file is not a program the engine compiles (an empty stage text is
            // refused, spec A R105), so such pairs are left out.
            if skip(&name) || is_stub(&vertex) || is_stub(&fragment) {
                continue;
            }
            let mut textures = present_textures();
            for t in textures.iter_mut().filter(|t| plane_slots.contains(&t.slot)) {
                t.video_planes = crate::request::VideoPlanes::Nv12Biplanar;
            }
            let request = ShaderRequest {
                shader_name: name.clone(),
                stages: vec![
                    Stage { kind: StageKind::Vertex, source: vertex },
                    Stage { kind: StageKind::Fragment, source: fragment },
                ],
                combos: combos.clone(),
                textures,
                ..ShaderRequest::default()
            }
            .validate()
            .unwrap();
            let label = format!("{name} ({set_name})");
            let started = std::time::Instant::now();
            let result = compile(&request, includes);
            let elapsed = started.elapsed();
            match result {
                Ok(program) => {
                    s.ok += 1;
                    s.micros.push(elapsed.as_micros());
                    check_program(&program, &label, &mut s);
                }
                Err(e) => {
                    if std::env::var("PIPELINE_SHOW").is_ok_and(|v| label.contains(&v)) {
                        eprintln!("=== {label}\n{e}\n");
                    }
                    let category = format!("{:?}", e.category());
                    s.failures.entry(format!("{category}: {}", cause(&e.to_string()))).or_default().push(label);
                }
            }
        }
    }
    s
}

/// Facts that hold for every compiled program.
fn check_program(program: &CompiledProgram, label: &str, s: &mut Sweep) {
    assert_eq!(program.stages.len(), 2, "{label}");
    for stage in &program.stages {
        assert!(stage.payload.msl_source.contains("#include <metal_stdlib>"), "{label}");
        assert!(!stage.payload.msl_source.contains('\0'), "{label}");
        assert_ne!(stage.payload.entry_point, "main", "{label}");
        for b in &stage.payload.bindings {
            if !in_vocabulary(&b.name) {
                s.refused_names.entry(b.name.clone()).or_default().push(label.to_string());
            }
        }
    }
    for d in &program.reflection.descriptor_bindings {
        assert_eq!(d.count, 1, "{label}");
    }
}

fn report(title: &str, s: &Sweep) {
    let failed: usize = s.failures.values().map(Vec::len).sum();
    let total = s.ok + failed;
    eprintln!("{title}: {} of {total} programs compiled end to end ({failed} failed)", s.ok);
    let mut times = s.micros.clone();
    times.sort_unstable();
    if let (Some(median), Some(worst)) = (times.get(times.len() / 2), times.last()) {
        eprintln!("  compile time: median {median} us, worst {worst} us over {} programs", times.len());
    }
    for (cause, labels) in &s.failures {
        eprintln!("  [{}] {cause}\n      e.g. {}", labels.len(), labels.iter().take(3).cloned().collect::<Vec<_>>().join(", "));
    }
    for (name, labels) in &s.refused_names {
        eprintln!("  binding name outside the host vocabulary: `{name}` in {} programs, e.g. {}", labels.len(), labels.iter().take(2).cloned().collect::<Vec<_>>().join(", "));
    }
}

#[test]
fn shipped_programs_compile_end_to_end() {
    let Some(root) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent (set WALLPAPER_MACHINE_ASSETS_ROOT)");
        return;
    };
    let files = shader_files(&root);
    let includes = Layered { dirs: vec![root.clone()] };
    // `HLSL/` holds Direct3D programs for another path and the volumetric shader is out of scope
    // (spec C1 R22); both are left out of the sweep, as the earlier parts do.
    let s = sweep(&files, &includes, |n| n.starts_with("HLSL/") || n.starts_with("volumetricsfront"), &[]);
    report("shipped programs", &s);
    for (cause, labels) in &s.failures {
        // The shadow-caster vertex stage of the foliage model reads `g_Texture1Texel`, which
        // no shipped file declares: nothing can translate it.
        assert!(cause.contains("Unknown variable: g_Texture1Texel"), "a shipped program fails: {cause}: {labels:?}");
        assert!(labels.iter().all(|l| l.starts_with("shadowcasterfoliage4 ")), "{labels:?}");
    }
    assert!(s.ok >= 158, "{} shipped programs compiled", s.ok);
    assert!(s.refused_names.is_empty(), "binding names the host would refuse: {:?}", s.refused_names.keys().collect::<Vec<_>>());
}

#[test]
fn shipped_programs_compile_as_the_video_plane_variant_when_they_can() {
    let Some(root) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent (set WALLPAPER_MACHINE_ASSETS_ROOT)");
        return;
    };
    let files = shader_files(&root);
    let includes = Layered { dirs: vec![root.clone()] };
    let s = sweep(&files, &includes, |n| n.starts_with("HLSL/") || n.starts_with("volumetricsfront"), &[0]);
    report("shipped programs, slot 0 as video planes", &s);
    assert!(s.ok >= 150, "{} plane variants compiled", s.ok);
    assert!(s.refused_names.is_empty(), "{:?}", s.refused_names.keys().collect::<Vec<_>>());
}

#[test]
fn workshop_programs_compile_end_to_end() {
    let Some(stock) = shaders_root() else {
        eprintln!("skipped: the shipped shader folder is absent");
        return;
    };
    let Some(workshop) = workshop_root() else {
        eprintln!("skipped: no unpacked workshop shaders under artifacts/p5/workshop-shaders (unpack scene.pkg copies there)");
        return;
    };
    let mut total = Sweep::default();
    let mut seen = std::collections::HashSet::new();
    let mut dirs: Vec<_> = fs::read_dir(&workshop).unwrap().filter_map(Result::ok).collect();
    dirs.sort_by_key(|e| e.file_name());
    for entry in dirs {
        let own = entry.path().join("shaders");
        let mut files = shader_files(&own);
        files.retain(|(name, kind, text)| seen.insert((name.clone(), *kind == StageKind::Vertex, text.clone())));
        let includes = Layered { dirs: vec![own.clone(), stock.clone()] };
        let s = sweep(&files, &includes, |_| false, &[]);
        total.ok += s.ok;
        total.micros.extend(s.micros);
        let id = entry.file_name().to_string_lossy().to_string();
        for (cause, labels) in s.failures {
            total.failures.entry(cause).or_default().extend(labels.into_iter().map(|l| format!("{id}/{l}")));
        }
        for (name, labels) in s.refused_names {
            total.refused_names.entry(name).or_default().extend(labels.into_iter().map(|l| format!("{id}/{l}")));
        }
    }
    report("workshop programs", &total);
    assert!(total.ok > 790, "{} workshop programs compiled", total.ok);
}

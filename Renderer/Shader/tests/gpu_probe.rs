// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Probes of the Metal backend that decide how the dialect front end spells a few constructs.
// They compile and run a small Swift program that dispatches a compute kernel (no window, no
// display), so they are opt-in: set WM_SHADER_GPU_PROBES=1. Without it the test prints why it
// did nothing.

use std::path::PathBuf;
use std::process::Command;

fn probe_output(script: &str) -> Option<String> {
    if std::env::var_os("WM_SHADER_GPU_PROBES").is_none() {
        eprintln!("skipped: set WM_SHADER_GPU_PROBES=1 to run the Metal probes (needs swiftc and a GPU)");
        return None;
    }
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("gpu_probe");
    std::fs::create_dir_all(&dir).unwrap();
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/probes").join(script);
    let binary = dir.join(script.trim_end_matches(".swift"));
    let compiled = Command::new("swiftc").arg("-O").arg(&source).arg("-o").arg(&binary).output();
    match compiled {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            eprintln!("skipped: swiftc failed: {}", String::from_utf8_lossy(&o.stderr));
            return None;
        }
        Err(e) => {
            eprintln!("skipped: swiftc is not available: {e}");
            return None;
        }
    }
    let run = Command::new(&binary).output().expect("the probe runs");
    let text = String::from_utf8_lossy(&run.stdout).to_string();
    if text.contains("no-device") {
        eprintln!("skipped: no Metal device");
        return None;
    }
    assert!(run.status.success(), "probe failed: {}", String::from_utf8_lossy(&run.stderr));
    Some(text)
}

/// Direct3D's `smoothstep`: the Hermite curve of the saturated ratio, whatever the order of the edges.
fn d3d_smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// The remainder with the sign of the dividend, which is what `%` on floats means (R47).
fn truncated_remainder(x: f32, y: f32) -> f32 {
    x - y * (x / y).trunc()
}

#[test]
fn metal_smoothstep_with_reversed_edges_is_the_direct3d_curve() {
    let Some(out) = probe_output("smoothstep_reversed.swift") else { return };
    let mut samples = 0;
    for line in out.lines().filter(|l| l.starts_with("sample ")) {
        let v: Vec<f32> = line.split_whitespace().skip(1).map(|t| t.parse().unwrap()).collect();
        let (x, runtime, literal, vector, fmod) = (v[0], v[1], v[2], v[3], v[4]);
        let want = d3d_smoothstep(0.9, 0.4, x);
        for (what, got) in [("runtime edges", runtime), ("literal edges", literal), ("vector", vector)] {
            assert!((got - want).abs() < 1e-4, "smoothstep(0.9, 0.4, {x}) with {what}: backend {got}, Direct3D {want}");
        }
        let rem = truncated_remainder(x * 7.0 - 3.0, 2.0);
        assert!((fmod - rem).abs() < 1e-4, "fmod({}, 2) = {fmod}, wanted {rem}", x * 7.0 - 3.0);
        samples += 1;
    }
    assert_eq!(samples, 7, "{out}");
}

// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Probes of the Metal backend that decide how the dialect front end spells a few constructs.
// They compile and run a small Swift program that dispatches a compute kernel (no window, no
// display), so they are opt-in: set WM_SHADER_GPU_PROBES=1. Without it the test prints why it
// did nothing.

use std::path::PathBuf;
use std::process::Command;
use std::sync::OnceLock;

use naga::back::msl;
use naga::front::glsl::{Frontend, Options};
use naga::valid::{Capabilities, ValidationFlags, Validator};
use wm_shader::StageKind;
use wm_shader::dialect::convert_stage;

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

// ----- evaluating converted shaders on the GPU -----

fn runner() -> Option<&'static PathBuf> {
    static RUNNER: OnceLock<Option<PathBuf>> = OnceLock::new();
    RUNNER
        .get_or_init(|| {
            if std::env::var_os("WM_SHADER_GPU_PROBES").is_none() {
                eprintln!("skipped: set WM_SHADER_GPU_PROBES=1 to run the Metal probes (needs swiftc and a GPU)");
                return None;
            }
            let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("gpu_probe");
            std::fs::create_dir_all(&dir).unwrap();
            let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/probes/run_kernel.swift");
            let binary = dir.join("run_kernel");
            match Command::new("swiftc").arg("-O").arg(&source).arg("-o").arg(&binary).output() {
                Ok(o) if o.status.success() => Some(binary),
                Ok(o) => {
                    eprintln!("skipped: swiftc failed: {}", String::from_utf8_lossy(&o.stderr));
                    None
                }
                Err(e) => {
                    eprintln!("skipped: swiftc is not available: {e}");
                    None
                }
            }
        })
        .as_ref()
}

/// Converts a compute kernel written in the dialect, writes it as Metal through naga and runs it
/// with one thread over `data` (the shader's `buffer` block of 64 floats). `None` when the probes
/// are off or the machine cannot run them.
fn gpu_run(glsl: &str, inputs: &[f32]) -> Option<Vec<f32>> {
    let runner = runner()?;
    let converted = convert_stage(StageKind::Fragment, glsl).unwrap_or_else(|d| panic!("{d:?}\n{glsl}"));
    let module = Frontend::default()
        .parse(&Options::from(naga::ShaderStage::Compute), &converted.text)
        .unwrap_or_else(|e| panic!("naga parse: {:?}\n{}", e.errors, converted.text));
    let info = Validator::new(ValidationFlags::all(), Capabilities::all())
        .validate(&module)
        .unwrap_or_else(|e| panic!("naga validate: {}\n{}", e.as_inner(), converted.text));
    let mut options = msl::Options { lang_version: (2, 0), fake_missing_bindings: false, ..Default::default() };
    let mut resources = msl::EntryPointResources::default();
    resources.resources.insert(
        naga::ResourceBinding { group: 0, binding: 0 },
        msl::BindTarget { buffer: Some(0), mutable: true, ..Default::default() },
    );
    options.per_entry_point_map.insert("main".to_string(), resources);
    let (text, _) = msl::write_string(&module, &info, &options, &msl::PipelineOptions::default())
        .unwrap_or_else(|e| panic!("msl: {e}\n{}", converted.text));
    let kernel = text
        .lines()
        .find_map(|l| l.strip_prefix("kernel void ").and_then(|r| r.split('(').next()))
        .unwrap_or_else(|| panic!("no kernel in\n{text}"))
        .to_string();
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("gpu_probe");
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let file = dir.join(format!("kernel_{}_{}.metal", std::process::id(), NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)));
    std::fs::write(&file, &text).unwrap();
    let mut cmd = Command::new(runner);
    cmd.arg(&file).arg(&kernel).arg("64");
    for v in inputs {
        cmd.arg(v.to_string());
    }
    let run = cmd.output().expect("the runner runs");
    let _ = std::fs::remove_file(&file);
    let out = String::from_utf8_lossy(&run.stdout).to_string();
    if out.contains("no-device") {
        eprintln!("skipped: no Metal device");
        return None;
    }
    assert!(run.status.success(), "runner failed: {out}{}\n{text}", String::from_utf8_lossy(&run.stderr));
    Some(out.lines().map(|l| l.parse().unwrap()).collect())
}

const KERNEL_HEAD: &str = "layout(local_size_x = 1) in;\nlayout(std430, set = 0, binding = 0) buffer Out { float data[64]; };\n";

fn near(a: f32, b: f32) -> bool {
    (a - b).abs() <= 1e-4 * (1.0 + b.abs())
}

#[test]
fn matrix_inverse_helpers_compute_exact_inverses_on_the_gpu() {
    // Each matrix is multiplied by its inverse; the products are the identity. The input floats keep
    // the compiler from folding the matrices away.
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  mat2 a = mat2(data[0], data[1], data[2], data[3]);
  mat3 b = mat3(data[4], data[5], data[6], data[7], data[8], data[9], data[10], data[11], data[12]);
  mat4 c = mat4(data[13], data[14], data[15], data[16], data[17], data[18], data[19], data[20],
                data[21], data[22], data[23], data[24], data[25], data[26], data[27], data[28]);
  mat2 pa = inverse(a) * a;
  mat3 pb = inverse(b) * b;
  mat4 pc = inverse(c) * c;
  for (int i = 0; i < 2; i++) for (int j = 0; j < 2; j++) data[29 + i * 2 + j] = pa[i][j];
  for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) data[33 + i * 3 + j] = pb[i][j];
  for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) data[42 + i * 4 + j] = pc[i][j];
}}"
    );
    let inputs: Vec<f32> = [
        2.0, 1.0, 1.0, 3.0, // mat2
        2.0, 0.0, 1.0, 1.0, 3.0, 0.0, 0.0, 1.0, 4.0, // mat3
        4.0, 1.0, 0.5, 0.0, 1.0, 3.0, 0.0, 1.0, 0.5, 0.0, 5.0, 2.0, -1.0, 0.0, 1.0, 2.0, // mat4
    ]
    .to_vec();
    let Some(out) = gpu_run(&src, &inputs) else { return };
    for (base, n) in [(29usize, 2usize), (33, 3), (42, 4)] {
        for i in 0..n {
            for j in 0..n {
                let want = if i == j { 1.0 } else { 0.0 };
                let got = out[base + i * n + j];
                assert!((got - want).abs() < 1e-4, "inverse {n}x{n} times itself at [{i}][{j}]: {got}");
            }
        }
    }
}

#[test]
fn converted_arithmetic_has_the_hlsl_values_on_the_gpu() {
    // data[0..8] are inputs; results go to data[8..].
    let src = format!(
        "{KERNEL_HEAD}void main() {{
  float f = data[0];            // -2.7
  float g = data[1];            // 2.0
  vec3 v = vec3(data[2], data[3], data[4]);   // 0.25, -0.5, 1.5
  float hit = data[5];          // 0.4
  data[8] = f % g;                              // truncated remainder, sign of the dividend
  data[9] = fmod(7.5, g + 0.0 * f);
  data[10] = float(int(f));                     // int k = f; truncation toward zero
  int k = f;
  data[11] = float(k);
  data[12] = frac(f);                           // 0.3
  data[13] = log10(100.0 + 0.0 * f);            // 2
  data[14] = saturate(f) + saturate(g * 0.25);  // 0 + 0.5
  data[15] = (hit > 0.3) * 0.75 + (hit > 0.5) * 2.0;   // bool in arithmetic: 0.75
  bool on = g;                                  // number as bool
  data[16] = on ? 1.0 : 0.0;
  if (!g) {{ data[17] = 5.0; }} else {{ data[17] = 6.0; }}      // ! on a number
  data[18] = (g && hit) ? 1.0 : 0.0;                         // && on numbers
  data[19] = lerp(0.0, 10.0, hit);
  data[20] = step(hit, 0.5) + step(0.5, hit);   // 1 + 0
  int lit = step(hit, 0.5);
  lit *= (g > 1.0);
  data[21] = float(lit + 1);                    // 2
  vec2 w = v;                                   // narrowing: first components
  data[22] = w.x + w.y * 10.0;                  // 0.25 - 5
  vec3 b = g;                                   // broadcast
  data[23] = b.x + b.y + b.z;                   // 6
  data[24] = float(uint(g) % 3u);               // integer remainder: 2
  data[25] = max(0, v.y) + min(v.z, 2);         // int literals in float builtins: 0 + 1.5
  data[26] = pow(g, 3);                         // 8
  data[27] = smoothstep(0.9, 0.4, hit);         // reversed edges, Direct3D curve
}}"
    );
    let Some(out) = gpu_run(&src, &[-2.7, 2.0, 0.25, -0.5, 1.5, 0.4]) else { return };
    let t = |x: f32, y: f32| x - y * (x / y).trunc();
    let smooth = {
        let t = ((0.4f32 - 0.9) / (0.4 - 0.9)).clamp(0.0, 1.0);
        t * t * (3.0 - 2.0 * t)
    };
    let want = [
        (8, t(-2.7, 2.0)),
        (9, t(7.5, 2.0)),
        (10, -2.0),
        (11, -2.0),
        (12, -2.7 - (-2.7f32).floor()),
        (13, 2.0),
        (14, 0.5),
        (15, 0.75),
        (16, 1.0),
        (17, 6.0),
        (18, 1.0),
        (19, 4.0),
        (20, 1.0),
        (21, 2.0),
        (22, 0.25 - 5.0),
        (23, 6.0),
        (24, 2.0),
        (25, 1.5),
        (26, 8.0),
        (27, smooth),
    ];
    for (i, w) in want {
        assert!(near(out[i], w), "data[{i}] = {}, wanted {w}", out[i]);
    }
}

#[test]
fn converted_matrices_arrays_and_globals_have_the_expected_values_on_the_gpu() {
    // data[0..16] are inputs; results go to data[16..].
    let src = format!(
        "{KERNEL_HEAD}
float taps[4];
const float GAIN = data[0] * 2.0;     // reads a run-time value: moved to the start of main
float pool(float v[4], float scale) {{ return (v[0] + v[1] * 2.0 + v[2] * 3.0 + v[3] * 4.0) * scale; }}
void main() {{
  for (int i = 0; i < 4; i++) {{ taps[i] = data[1 + i]; }}               // 1 2 3 4 from data[1..5]
  vec3 p = vec3(data[5], data[6], data[7]);                               // 1 2 3
  mat4x3 m = mat4x3(data[8], 0.0, 0.0, 0.0, data[9], 0.0, 0.0, 0.0, data[10], 1.0, 2.0, 3.0);
  vec3 moved = mul(vec4(p, 1.0), m);              // (m * v): 2*1+1, 3*2+2, 4*3+3
  data[16] = moved.x; data[17] = moved.y; data[18] = moved.z;
  mat3 r = CAST3X3(m);
  vec3 rot = mul(p, r);                           // p * r (the transposed product)
  data[19] = rot.x; data[20] = rot.y; data[21] = rot.z;
  data[22] = pool(taps, 0.5);                     // (1 + 4 + 9 + 16) * 0.5 = 15
  data[23] = GAIN;                                // 2 * data[0]
  float t = data[11] * 3.0;                       // 3.3 -> index 3
  data[24] = taps[t];                             // float subscript: taps[3] = 4
  float acc = 0.0;
  for (int k = data[12]; k < 4.0; k++) {{ acc += float(k); }}   // starts at 1: 1 + 2 + 3
  data[25] = acc;
  ivec3 iv = ivec3(1, 2, 3);
  vec3 sc = iv * vec3(0.5);                       // integer vector beside a float vector
  data[26] = sc.x + sc.y + sc.z;                  // 3
  uint u = 7u; int n = 3;
  data[27] = float(u % uint(n));                  // 1
  data[28] = (data[13] > 0.5) ? 1 : 2.5;          // ternary promotes to float: 1
  vec2 a2 = vec2(data[14], data[15]);
  vec3 b3 = vec3(1.0, 2.0, 3.0);
  vec2 s2 = a2 + b3;                              // mixed widths: the 3-vector is cut to 2
  data[29] = s2.x; data[30] = s2.y;
}}"
    );
    let inputs = [1.5, 1.0, 2.0, 3.0, 4.0, 1.0, 2.0, 3.0, 2.0, 3.0, 4.0, 1.1, 1.9, 0.9, 10.0, 20.0];
    let Some(out) = gpu_run(&src, &inputs) else { return };
    let want = [
        (16, 2.0 * 1.0 + 1.0),
        (17, 3.0 * 2.0 + 2.0),
        (18, 4.0 * 3.0 + 3.0),
        // p * r with r = diag(2, 3, 4) in its first three columns: component-wise 1*2, 2*3, 3*4
        (19, 2.0),
        (20, 6.0),
        (21, 12.0),
        (22, 15.0),
        (23, 3.0),
        (24, 4.0),
        (25, 1.0 + 2.0 + 3.0),
        (26, 3.0),
        (27, 1.0),
        (28, 1.0),
        (29, 11.0),
        (30, 22.0),
    ];
    for (i, w) in want {
        assert!(near(out[i], w), "data[{i}] = {}, wanted {w}", out[i]);
    }
}

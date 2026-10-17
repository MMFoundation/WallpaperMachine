// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Runs the pipeline's front end over Wallpaper Engine's shipped shaders. The
// shaders are third-party test input, never committed; the tests skip with a
// printed reason when the asset folder is absent.

use std::fs;
use std::path::{Path, PathBuf};

use wm_shader::include::{IncludeError, IncludeErrorKind};
use wm_shader::preprocess::{Mode, preprocess_stage};
use wm_shader::source::IncludeSource;
use wm_shader::{Combo, StageKind};

/// The shipped shader folder: `WALLPAPER_MACHINE_ASSETS_ROOT` (the folder that holds `shaders/`)
/// or the default application support location.
fn shaders_root() -> Option<PathBuf> {
    let root = match std::env::var_os("WALLPAPER_MACHINE_ASSETS_ROOT") {
        Some(dir) => PathBuf::from(dir).join("shaders"),
        None => {
            let home = std::env::var_os("HOME")?;
            PathBuf::from(home).join("Library/Application Support/WallpaperMachine/SceneAssets/shaders")
        }
    };
    root.is_dir().then_some(root)
}

macro_rules! require_assets {
    () => {
        match shaders_root() {
            Some(root) => root,
            None => {
                eprintln!("skipped: the shipped shader folder is absent (set WALLPAPER_MACHINE_ASSETS_ROOT)");
                return;
            }
        }
    };
}

struct DiskIncludes(PathBuf);

impl IncludeSource for DiskIncludes {
    fn read(&self, path: &str) -> Result<String, IncludeError> {
        let err = |kind| IncludeError { path: path.to_string(), kind };
        match fs::read(self.0.join(path)) {
            Ok(bytes) => String::from_utf8(bytes).map_err(|_| err(IncludeErrorKind::NotUtf8)),
            Err(_) => Err(err(IncludeErrorKind::NotFound)),
        }
    }
}

/// Every `.vert` and `.frag` below `root`, as (relative path without extension, kind, text).
fn shader_files(root: &Path) -> Vec<(String, StageKind, String)> {
    fn walk(dir: &Path, root: &Path, out: &mut Vec<(String, StageKind, String)>) {
        let mut entries: Vec<_> = fs::read_dir(dir).unwrap().filter_map(Result::ok).collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, root, out);
                continue;
            }
            let kind = match path.extension().and_then(|e| e.to_str()) {
                Some("vert") => StageKind::Vertex,
                Some("frag") => StageKind::Fragment,
                _ => continue,
            };
            let rel = path.strip_prefix(root).unwrap().with_extension("");
            let Ok(text) = fs::read_to_string(&path) else { continue };
            out.push((rel.to_string_lossy().replace('\\', "/"), kind, text));
        }
    }
    let mut out = Vec::new();
    walk(root, root, &mut out);
    out
}

fn combo(name: &str, value: &str) -> Combo {
    Combo { name: name.into(), value: value.into() }
}

fn combo_sets() -> Vec<(&'static str, Vec<Combo>)> {
    vec![
        ("no combos", vec![]),
        (
            "lit and fogged",
            vec![
                combo("LIGHTING", "1"),
                combo("LIGHTS_POINT", "2"),
                combo("LIGHTS_SPOT", "1"),
                combo("LIGHTS_TUBE", "1"),
                combo("LIGHTS_DIRECTIONAL", "1"),
                combo("FOG", "1"),
                combo("FOG_COMPUTED", "1"),
                combo("FOG_DIST", "1"),
                combo("FOG_HEIGHT", "1"),
                combo("TEX0FORMAT", "9"),
                combo("TEX1FORMAT", "8"),
                combo("SCENE_ORTHO", "1"),
            ],
        ),
        (
            "skinned and reflective",
            vec![
                combo("SKINNING", "1"),
                combo("MORPHING", "1"),
                combo("BONECOUNT", "4"),
                combo("REFLECTION", "1"),
                combo("NORMALMAP", "1"),
                combo("BLENDMODE", "9"),
                combo("HDR", "1"),
            ],
        ),
    ]
}

#[test]
fn every_shipped_stage_preprocesses_in_both_modes() {
    let root = require_assets!();
    let files = shader_files(&root);
    assert!(files.len() > 50, "found only {} shader files under {}", files.len(), root.display());
    let includes = DiskIncludes(root.clone());
    let mut failures = Vec::new();
    for (set_name, combos) in combo_sets() {
        for (name, kind, text) in &files {
            for mode in [Mode::Evaluated, Mode::MetadataPreserving] {
                if let Err(e) = preprocess_stage(*kind, text, &combos, &includes, mode) {
                    failures.push(format!("{name} ({set_name}, {mode:?}): {e}"));
                }
            }
        }
    }
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
    eprintln!("preprocessed {} stages x {} combo sets x 2 modes", files.len(), combo_sets().len());
}

#[test]
fn lit_shaders_expand_the_lighting_block() {
    let root = require_assets!();
    let includes = DiskIncludes(root.clone());
    let lights = vec![
        combo("LIGHTING", "1"),
        combo("LIGHTS_POINT", "2"),
        combo("LIGHTS_SPOT", "1"),
        combo("LIGHTS_TUBE", "1"),
        combo("LIGHTS_DIRECTIONAL", "1"),
    ];
    let mut checked = 0;
    for (name, kind, text) in shader_files(&root) {
        if !text.contains("#require LightingV1") && !text.contains("LightingV1") {
            continue;
        }
        let out = preprocess_stage(kind, &text, &lights, &includes, Mode::Evaluated).unwrap_or_else(|e| panic!("{name}: {e}"));
        // Only a stage whose `#require` is active gets the block.
        if text.contains("#require LightingV1") {
            let unlit = preprocess_stage(kind, &text, &[], &includes, Mode::Evaluated).unwrap();
            assert!(!unlit.text.contains("PerformLighting_V1(vec3 worldPos"), "{name}");
            if out.text.contains("PerformLighting_V1(vec3 worldPos") {
                assert!(out.text.contains("uniform vec4 g_LPoint_Color[2];"), "{name}");
                checked += 1;
            }
        }
    }
    assert!(checked > 0, "no stock stage requires the lighting block under the given combos");
}

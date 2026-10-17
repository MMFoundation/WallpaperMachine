// This project's own code, written from the clean-room specification (no upstream code consulted).
#![allow(dead_code)]
//
//! Helpers shared by the pipeline tests.

use crate::error::ShaderError;
use crate::pipeline::{CompiledProgram, compile};
use crate::request::{Combo, ShaderRequest, Stage, StageKind, TextureRecord, ValidRequest};
use crate::source::{MemorySource, NoIncludes};

pub const PASS_VERTEX: &str = "\
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
";

pub const PASS_FRAGMENT: &str = "\
varying vec2 v_TexCoord;
void main() { gl_FragColor = vec4(v_TexCoord, 0.0, 1.0); }
";

/// A request builder: vertex and fragment text, combos and textures.
#[derive(Clone, Default)]
pub struct Req {
    pub name: String,
    pub vertex: String,
    pub fragment: String,
    pub combos: Vec<(String, String)>,
    pub textures: Vec<TextureRecord>,
    pub fragment_first: bool,
}

impl Req {
    pub fn new(vertex: &str, fragment: &str) -> Req {
        Req { name: "test/shader".into(), vertex: vertex.into(), fragment: fragment.into(), ..Req::default() }
    }

    pub fn combo(mut self, name: &str, value: &str) -> Req {
        self.combos.push((name.into(), value.into()));
        self
    }

    pub fn texture(mut self, record: TextureRecord) -> Req {
        self.textures.push(record);
        self
    }

    pub fn fragment_first(mut self) -> Req {
        self.fragment_first = true;
        self
    }

    pub fn build(&self) -> ValidRequest {
        let mut stages = vec![
            Stage { kind: StageKind::Vertex, source: self.vertex.clone() },
            Stage { kind: StageKind::Fragment, source: self.fragment.clone() },
        ];
        if self.fragment_first {
            stages.reverse();
        }
        ShaderRequest {
            shader_name: self.name.clone(),
            stages,
            combos: self.combos.iter().map(|(n, v)| Combo { name: n.clone(), value: v.clone() }).collect(),
            textures: self.textures.clone(),
            ..ShaderRequest::default()
        }
        .validate()
        .expect("a valid request")
    }

    pub fn compile(&self) -> Result<CompiledProgram, ShaderError> {
        compile(&self.build(), &NoIncludes)
    }

    pub fn compile_with(&self, includes: &MemorySource) -> Result<CompiledProgram, ShaderError> {
        compile(&self.build(), includes)
    }

    pub fn ok(&self) -> CompiledProgram {
        match self.compile() {
            Ok(p) => p,
            Err(e) => panic!("compile failed:\n{e}\n--- vertex ---\n{}\n--- fragment ---\n{}", self.vertex, self.fragment),
        }
    }

    pub fn err(&self) -> ShaderError {
        match self.compile() {
            Ok(p) => panic!("compile should have failed, got:\n{}\n{}", p.stages[0].glsl, p.stages[1].glsl),
            Err(e) => e,
        }
    }
}

pub fn ok(vertex: &str, fragment: &str) -> CompiledProgram {
    Req::new(vertex, fragment).ok()
}

pub fn err(vertex: &str, fragment: &str) -> ShaderError {
    Req::new(vertex, fragment).err()
}

pub fn texture(slot: u8) -> TextureRecord {
    let mut t = TextureRecord::new(slot);
    t.enabled = true;
    t
}

/// The `[[user(locN)]]` members of the struct `name` of an MSL text: `(member, N)` in order.
pub fn user_locations(msl: &str, name: &str) -> Vec<(String, u32)> {
    let mut out = Vec::new();
    let mut inside = false;
    for line in msl.lines() {
        let line = line.trim();
        if line == format!("struct {name} {{") {
            inside = true;
        } else if inside && line == "};" {
            break;
        } else if inside && let Some(at) = line.find("[[user(loc") {
            let number: String = line[at + 10..].chars().take_while(char::is_ascii_digit).collect();
            let member = line[..at].trim().rsplit(' ').next().unwrap().to_string();
            out.push((member, number.parse().unwrap()));
        }
    }
    out
}

/// `(member, location)` pairs of one side of the interface.
pub type Locations = Vec<(String, u32)>;

/// The vertex outputs and fragment inputs of a compiled program, by `[[user(locN)]]`.
pub fn interface_of(p: &CompiledProgram) -> (Locations, Locations) {
    let v = &p.stage(StageKind::Vertex).unwrap().payload.msl_source;
    let f = &p.stage(StageKind::Fragment).unwrap().payload.msl_source;
    (user_locations(v, "main_Output"), user_locations(f, "main_Input"))
}

/// The `layout(location = N)` of the declaration of `name` in a legalized text.
pub fn declared_location(glsl: &str, name: &str) -> Option<u32> {
    glsl.lines().find_map(|l| {
        let rest = l.strip_prefix("layout(location = ")?;
        let (number, decl) = rest.split_once(')')?;
        let declared = decl.split(';').next()?.trim().rsplit(' ').next()?;
        (declared.split('[').next() == Some(name)).then(|| number.parse().unwrap())
    })
}

/// The type spelling of the declaration of the interface variable `name` in a legalized text.
pub fn declared_type(glsl: &str, name: &str) -> Option<String> {
    glsl.lines().find_map(|l| {
        l.strip_prefix("layout(location = ")?;
        let decl = l.split_once(')')?.1.split(';').next()?.trim();
        let mut words: Vec<&str> = decl.split(' ').collect();
        let last = words.pop()?;
        (last.split('[').next() == Some(name)).then(|| words.last().unwrap_or(&"").to_string())
    })
}

/// A vertex stage that declares the given varying lines and writes each one.
pub fn vertex_with(declarations: &str, body: &str) -> String {
    format!("attribute vec3 a_Position;\nattribute vec2 a_Coord;\n{declarations}\nvoid main() {{\n  gl_Position = vec4(a_Position, 1.0);\n{body}\n}}\n")
}

/// A fragment stage that declares the given varying lines and runs `body`.
pub fn fragment_with(declarations: &str, body: &str) -> String {
    format!("{declarations}\nvoid main() {{\n  vec4 c = vec4(0.0);\n{body}\n  gl_FragColor = c;\n}}\n")
}

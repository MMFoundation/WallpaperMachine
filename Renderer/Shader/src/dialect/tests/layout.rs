// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! A stand-in for the interface and resource layout step (a later part of the pipeline),
//! used only by tests: it turns a converted stage into text naga accepts by giving the
//! interface variables explicit locations, gathering the uniforms into one block and splitting
//! each `sampler2D` into a texture and a sampler. It is deliberately minimal.

use std::collections::HashSet;

use crate::dialect::Converted;
use crate::dialect::ast::*;
use crate::dialect::print::module_to_string;
use crate::request::StageKind;

fn is_sampler(name: &str) -> bool {
    matches!(name, "sampler2D" | "sampler3D" | "samplerCube" | "sampler2DArray")
}

fn rewrite_stmt(s: &mut Stmt, f: &mut dyn FnMut(&mut Expr)) {
    let decl = |d: &mut VarDecl, f: &mut dyn FnMut(&mut Expr)| {
        for x in d.declarators.iter_mut() {
            if let Some(i) = &mut x.init {
                rewrite_expr(i, f);
            }
        }
    };
    match s {
        Stmt::Block(list) | Stmt::Seq(list) => list.iter_mut().for_each(|s| rewrite_stmt(s, f)),
        Stmt::Decl(d) => decl(d, f),
        Stmt::Expr(e) => rewrite_expr(e, f),
        Stmt::If { cond, then, otherwise } => {
            rewrite_expr(cond, f);
            rewrite_stmt(then, f);
            if let Some(o) = otherwise {
                rewrite_stmt(o, f);
            }
        }
        Stmt::For { init, cond, step, body } => {
            if let Some(i) = init {
                rewrite_stmt(i, f);
            }
            if let Some(c) = cond {
                rewrite_expr(c, f);
            }
            if let Some(s) = step {
                rewrite_expr(s, f);
            }
            rewrite_stmt(body, f);
        }
        Stmt::While { cond, body } | Stmt::DoWhile { body, cond } => {
            rewrite_expr(cond, f);
            rewrite_stmt(body, f);
        }
        Stmt::Switch { value, body } => {
            rewrite_expr(value, f);
            body.iter_mut().for_each(|s| rewrite_stmt(s, f));
        }
        Stmt::Return(Some(e), _) | Stmt::Case(e) => rewrite_expr(e, f),
        _ => {}
    }
}

fn rewrite_module(m: &mut Module, f: &mut dyn FnMut(&mut Expr)) {
    for item in m.items.iter_mut() {
        match item {
            Item::Var(d) => {
                for x in d.declarators.iter_mut() {
                    if let Some(i) = &mut x.init {
                        rewrite_expr(i, f);
                    }
                }
            }
            Item::Function(func) => {
                if let Some(body) = &mut func.body {
                    body.iter_mut().for_each(|s| rewrite_stmt(s, f));
                }
            }
            _ => {}
        }
    }
}

/// The converted stage with explicit interface and resource declarations.
pub fn naga_ready(kind: StageKind, converted: &Converted) -> String {
    let mut module = converted.module.clone();
    let mut samplers: Vec<(String, String)> = Vec::new();
    let mut block_members: Vec<VarDecl> = Vec::new();
    let mut widened: HashSet<String> = HashSet::new();
    let mut decls: Vec<Item> = Vec::new();
    let mut rest: Vec<Item> = Vec::new();
    let (mut loc_in, mut loc_out, mut binding) = (0u32, 0u32, 1u32);
    for item in std::mem::take(&mut module.items) {
        let Item::Var(mut d) = item else {
            rest.push(item);
            continue;
        };
        d.quals.retain(|q| !matches!(q, Qualifier::Word(w) if matches!(w.as_str(), "lowp" | "mediump" | "highp")));
        let has = |w: &str| d.quals.iter().any(|q| q.is_word(w));
        if has("uniform") {
            if is_sampler(&d.ty.name) {
                for decl in &d.declarators {
                    samplers.push((decl.name.clone(), d.ty.name.clone()));
                    let tex = match d.ty.name.as_str() {
                        "sampler3D" => "texture3D",
                        "samplerCube" => "textureCube",
                        "sampler2DArray" => "texture2DArray",
                        _ => "texture2D",
                    };
                    let src = format!(
                        "layout(set = 0, binding = {}) uniform {tex} {};\nlayout(set = 0, binding = {}) uniform sampler _s_{};\n",
                        binding,
                        decl.name,
                        binding + 1,
                        decl.name
                    );
                    binding += 2;
                    let (m, _) = crate::dialect::parse_stage(kind, &src).unwrap();
                    decls.extend(m.items);
                }
            } else {
                for decl in d.declarators {
                    let mut one = VarDecl { quals: Vec::new(), ty: d.ty.clone(), declarators: vec![decl], span: d.span.clone() };
                    // Scalar and 2-vector arrays have a stride of 16 in a uniform block: widen them
                    // to vec4 elements and select the component where they are read.
                    let scalar_array = !one.declarators[0].dims.is_empty()
                        && matches!(one.ty.name.as_str(), "float" | "int" | "uint" | "vec2" | "ivec2");
                    if scalar_array {
                        widened.insert(one.declarators[0].name.clone());
                        one.ty = TypeRef::named(match one.ty.name.as_str() {
                            "int" | "ivec2" => "ivec4",
                            "uint" => "uvec4",
                            _ => "vec4",
                        });
                    }
                    block_members.push(one);
                }
            }
            continue;
        }
        let attribute_like = has("attribute") || (has("in") && kind == StageKind::Vertex);
        let varying_out = has("varying") && kind == StageKind::Vertex || has("out");
        let varying_in = has("varying") && kind == StageKind::Fragment || (has("in") && kind == StageKind::Fragment);
        if attribute_like || varying_out || varying_in {
            let dir = if attribute_like || varying_in { "in" } else { "out" };
            for decl in d.declarators {
                let loc = if dir == "in" { &mut loc_in } else { &mut loc_out };
                let n: u32 = decl.dims.first().and_then(|x| x.as_ref()).and_then(|e| if let ExprKind::Number(t) = &e.kind { t.parse().ok() } else { None }).unwrap_or(1);
                let flat = if matches!(d.ty.name.as_str(), "int" | "uint" | "ivec2" | "ivec3" | "ivec4" | "uvec2" | "uvec3" | "uvec4") && kind == StageKind::Fragment && dir == "in" { "flat " } else { "" };
                let one = VarDecl {
                    quals: vec![Qualifier::Layout(format!("location = {loc}")), Qualifier::Word(format!("{flat}{dir}").trim().to_string())],
                    ty: d.ty.clone(),
                    declarators: vec![decl],
                    span: d.span.clone(),
                };
                *loc += n;
                decls.push(Item::Var(one));
            }
            continue;
        }
        rest.push(Item::Var(d));
    }
    // Reads of widened arrays select the component.
    let mut m = Module { items: rest };
    if !widened.is_empty() {
        rewrite_module(&mut m, &mut |e| {
            if let ExprKind::Index(base, _) = &e.kind
                && matches!(&base.kind, ExprKind::Ident(n) if widened.contains(n)) {
                    let inner = std::mem::replace(e, Expr::number("0", 0..0));
                    *e = Expr::new(ExprKind::Member(Box::new(inner), "x".to_string()), 0..0);
                }
        });
    }
    let mut out = String::from(crate::dialect::HEADER);
    for d in &decls {
        let mut t = String::new();
        crate::dialect::print::write_item(&mut t, d);
        out.push_str(&t);
    }
    // Per-texture values the resource part supplies (`g_Texture1Texel`, `g_Texture0Resolution`, ...).
    let body_text = module_to_string(&Module { items: m.items.clone() });
    for n in 0..13 {
        for suffix in ["Texel", "Resolution", "Rotation", "Translation"] {
            let name = format!("g_Texture{n}{suffix}");
            if has_word_in(&body_text, &name) && !block_members.iter().any(|b| b.declarators[0].name == name) {
                let src = format!("uniform vec4 {name};");
                let (parsed, _) = crate::dialect::parse_stage(kind, &src).unwrap();
                if let Some(Item::Var(v)) = parsed.items.into_iter().next() {
                    block_members.push(VarDecl { quals: Vec::new(), ..v });
                }
            }
        }
    }
    if !block_members.is_empty() {
        out.push_str("layout(std140, set = 0, binding = 0) uniform GlobalUniforms {\n");
        for mem in &block_members {
            let mut t = String::new();
            crate::dialect::print::write_item(&mut t, &Item::Var(mem.clone()));
            out.push_str("  ");
            out.push_str(&t);
        }
        out.push_str("};\n");
    }
    if kind == StageKind::Fragment && converted_text_mentions(&module_to_string(&m), "gl_FragColor") {
        out.push_str("layout(location = 0) out vec4 _fragColor;\n");
    }
    let mut body = module_to_string(&m);
    body = body.replace("gl_FragColor", "_fragColor");
    for (name, ty) in &samplers {
        for func in ["texture", "textureLod", "textureGrad", "textureOffset", "textureProj"] {
            body = body.replace(&format!("{func}({name},"), &format!("{func}({ty}({name}, _s_{name}),"));
        }
    }
    out.push_str(&body);
    out
}

fn converted_text_mentions(text: &str, word: &str) -> bool {
    text.contains(word)
}

fn has_word_in(text: &str, word: &str) -> bool {
    let is_id = |c: char| c.is_ascii_alphanumeric() || c == '_';
    text.match_indices(word).any(|(i, _)| {
        text[..i].chars().next_back().is_none_or(|c| !is_id(c)) && text[i + word.len()..].chars().next().is_none_or(|c| !is_id(c))
    })
}

// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Wallpaper Engine shader text in, Metal Shading Language and reflection out.
//!
//! This crate is the shader layer of the renderer. Its public model (requests,
//! responses, reflection, diagnostics, errors, cache identity) does not depend
//! on the compiler; the compiler pipeline plugs into it.
#![deny(warnings)]
#![cfg_attr(not(feature = "ffi"), forbid(unsafe_code))]

pub mod binding;
pub mod cache_key;
pub mod diagnostic;
pub mod error;
pub mod identity;
pub mod include;
pub mod json;
pub mod lexer;
pub mod names;
pub mod preprocess;
pub mod reflection;
pub mod request;
pub mod request_json;
pub mod response;
pub mod source;
mod sha256;
mod text;
pub mod uniforms;

pub use error::ShaderError;
pub use request::*;
pub use request_json::{parse_request, parse_request_bytes};

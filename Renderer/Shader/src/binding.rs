// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The per-stage Metal binding map (spec 2.6.1, R31 to R40, R104): one record
//! per shader resource, naming the resource by its original shader-visible
//! name and the Metal argument-table slot it was given.

use std::fmt;

use crate::json;
use crate::names::{SlotName, classify_slot_name, is_valid_resource_name};
use crate::text::{quote, sanitize};

/// Which Metal argument-table namespace a slot is in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SlotKind {
    Buffer,
    Texture,
    Sampler,
}

impl SlotKind {
    pub fn name(self) -> &'static str {
        match self {
            SlotKind::Buffer => "buffer",
            SlotKind::Texture => "texture",
            SlotKind::Sampler => "sampler",
        }
    }

    /// The highest slot of this namespace the layer hands out (R35). Buffers
    /// stop at 30 so the uniform block cannot collide with vertex streams.
    pub fn max_slot(self) -> u32 {
        match self {
            SlotKind::Buffer => 30,
            SlotKind::Texture => 127,
            SlotKind::Sampler => 15,
        }
    }
}

/// One resource of one stage.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    /// The original shader-visible name (`GlobalUniforms`, `g_Texture0`, `_we_Sampler_g_Texture0`).
    pub name: String,
    /// Always 0: Metal has no descriptor sets, the field is kept for the engine's reader (R96).
    pub set: u32,
    /// The resource index, unique across kinds within the program.
    pub binding: u32,
    pub slot_kind: SlotKind,
    /// The Metal argument-table index within its kind. Equal to `binding` for a buffer and a
    /// texture; the dense rank among the program's samplers for a sampler (C2 R88, see
    /// [`assign_metal_slots`]).
    pub slot: u32,
}

impl Binding {
    /// Maps a buffer or texture to its Metal slot (the slot is the binding), or says why it
    /// cannot be mapped (a sampler goes through [`assign_metal_slots`], whose slot is not its
    /// binding):
    /// a name that is not an ASCII identifier (R104), a descriptor set other
    /// than 0 or no binding at all (R34), or a slot above the limit of its
    /// namespace (R35). The layer never invents a slot.
    pub fn for_resource(
        name: &str,
        set: u32,
        binding: Option<u32>,
        slot_kind: SlotKind,
    ) -> Result<Binding, BindingError> {
        if !is_valid_resource_name(name) {
            return Err(BindingError::InvalidName { name: name.to_string() });
        }
        if set != 0 {
            return Err(BindingError::UnmappableSet { name: name.to_string(), set });
        }
        let Some(binding) = binding else {
            return Err(BindingError::NoBinding { name: name.to_string() });
        };
        if binding > slot_kind.max_slot() {
            return Err(BindingError::SlotLimit { kind: slot_kind, slot: binding, name: name.to_string() });
        }
        Ok(Binding { name: name.to_string(), set: 0, binding, slot_kind, slot: binding })
    }

    /// One object of the per-stage `bindings` array, keys in the order of spec 2.6.1.
    pub fn to_json(&self) -> String {
        json::object(&[
            ("name", json::string(&self.name)),
            ("set", self.set.to_string()),
            ("binding", self.binding.to_string()),
            ("slot_kind", json::string(self.slot_kind.name())),
            ("slot", self.slot.to_string()),
        ])
    }
}

/// A resource that cannot be given a Metal slot, or a name that cannot be used.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BindingError {
    InvalidName { name: String },
    UnmappableSet { name: String, set: u32 },
    NoBinding { name: String },
    SlotLimit { kind: SlotKind, slot: u32, name: String },
    NonCanonicalTextureName { name: String },
    DuplicateTextureIndex { index: u32, first: String, second: String },
}

impl fmt::Display for BindingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            BindingError::InvalidName { name } => format!(
                "metal binding map cannot name a global resource: {} is not an ASCII identifier",
                quote(name)
            ),
            BindingError::UnmappableSet { name, set } => format!(
                "metal binding map cannot cover global {}: it uses descriptor set {set}",
                quote(name)
            ),
            BindingError::NoBinding { name } => format!(
                "metal binding map cannot cover global {}: it has no binding and no slot can be invented",
                quote(name)
            ),
            BindingError::SlotLimit { kind, slot, name } => format!(
                "metal binding map: resource {} needs {} slot {slot}, above the argument-table limit of {} for {} slots",
                quote(name),
                kind.name(),
                kind.max_slot(),
                kind.name()
            ),
            BindingError::NonCanonicalTextureName { name } => {
                format!("{} is not a canonical g_TextureN binding name", quote(name))
            }
            BindingError::DuplicateTextureIndex { index, first, second } => format!(
                "textures {} and {} both encode resource index {index}",
                quote(first),
                quote(second)
            ),
        };
        f.write_str(&sanitize(&text))
    }
}

impl std::error::Error for BindingError {}

/// R31: a name that starts with `g_Texture` and digits with a leading zero is
/// an error in whichever pass first sees it.
pub fn check_canonical_texture_name(name: &str) -> Result<(), BindingError> {
    match classify_slot_name(name) {
        SlotName::NonCanonical => Err(BindingError::NonCanonicalTextureName { name: name.to_string() }),
        _ => Ok(()),
    }
}

/// One resource of a program, as the layout decided it (the input of [`assign_metal_slots`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProgramResource {
    pub name: String,
    pub set: u32,
    pub binding: Option<u32>,
    pub kind: SlotKind,
}

/// The Metal slots of a whole program (R88): a buffer or texture keeps the value of its
/// binding index; a sampler takes its dense rank among the program's samplers (unique by
/// name, both stages, video chroma samplers included) counted from 0 in ascending binding
/// order. A program with more than sixteen distinct samplers fails naming the limit.
pub fn assign_metal_slots(resources: &[ProgramResource]) -> Result<Vec<Binding>, BindingError> {
    let mut out: Vec<Binding> = Vec::with_capacity(resources.len());
    let mut samplers: Vec<(u32, &ProgramResource)> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for r in resources {
        if !seen.insert((r.name.as_str(), r.kind.name())) {
            continue;
        }
        match r.kind {
            SlotKind::Sampler => {
                if !is_valid_resource_name(&r.name) {
                    return Err(BindingError::InvalidName { name: r.name.clone() });
                }
                if r.set != 0 {
                    return Err(BindingError::UnmappableSet { name: r.name.clone(), set: r.set });
                }
                let Some(binding) = r.binding else {
                    return Err(BindingError::NoBinding { name: r.name.clone() });
                };
                samplers.push((binding, r));
            }
            kind => out.push(Binding::for_resource(&r.name, r.set, r.binding, kind)?),
        }
    }
    samplers.sort_by_key(|(binding, r)| (*binding, r.name.clone()));
    for (rank, (binding, r)) in samplers.into_iter().enumerate() {
        let slot = rank as u32;
        if slot > SlotKind::Sampler.max_slot() {
            return Err(BindingError::SlotLimit { kind: SlotKind::Sampler, slot, name: r.name.clone() });
        }
        out.push(Binding { name: r.name.clone(), set: 0, binding, slot_kind: SlotKind::Sampler, slot });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limits_are_per_namespace() {
        assert_eq!((SlotKind::Buffer.max_slot(), SlotKind::Texture.max_slot(), SlotKind::Sampler.max_slot()), (30, 127, 15));
        assert!(Binding::for_resource("GlobalUniforms", 0, Some(30), SlotKind::Buffer).is_ok());
        assert!(Binding::for_resource("g_Texture0", 0, Some(127), SlotKind::Texture).is_ok());
        assert!(Binding::for_resource("_we_Sampler_g_Texture0", 0, Some(15), SlotKind::Sampler).is_ok());
    }

    #[test]
    fn a_slot_beyond_its_limit_names_kind_slot_resource_and_limit() {
        let e = Binding::for_resource("_we_Sampler_g_Texture11", 0, Some(20), SlotKind::Sampler).unwrap_err();
        let text = e.to_string();
        for needle in ["sampler", "20", "`_we_Sampler_g_Texture11`", "15"] {
            assert!(text.contains(needle), "{needle}: {text}");
        }
        let text = Binding::for_resource("GlobalUniforms", 0, Some(31), SlotKind::Buffer).unwrap_err().to_string();
        assert!(text.contains("buffer") && text.contains("31") && text.contains("30") && text.contains("GlobalUniforms"), "{text}");
        assert!(Binding::for_resource("g_Texture9", 0, Some(128), SlotKind::Texture).is_err());
    }

    #[test]
    fn only_set_zero_with_a_binding_can_be_mapped() {
        let text = Binding::for_resource("g_Cube", 1, Some(0), SlotKind::Texture).unwrap_err().to_string();
        assert!(text.contains("metal binding map cannot cover global `g_Cube`: it uses descriptor set 1"), "{text}");
        let text = Binding::for_resource("g_Cube", 0, None, SlotKind::Texture).unwrap_err().to_string();
        assert!(text.contains("metal binding map cannot cover global `g_Cube`"), "{text}");
    }

    #[test]
    fn names_must_be_ascii_identifiers() {
        for bad in ["", "1x", "a-b", "é", "a b"] {
            let text = Binding::for_resource(bad, 0, Some(0), SlotKind::Texture).unwrap_err().to_string();
            assert!(text.contains("metal binding map cannot name a global resource"), "{text}");
        }
        assert!(Binding::for_resource("a.b", 0, Some(0), SlotKind::Texture).is_ok());
    }

    #[test]
    fn the_slot_equals_the_resource_index() {
        let b = Binding::for_resource("g_Texture3", 0, Some(3), SlotKind::Texture).unwrap();
        assert_eq!((b.binding, b.slot, b.set), (3, 3, 0));
    }

    #[test]
    fn json_has_the_required_keys_in_order() {
        let b = Binding::for_resource("GlobalUniforms", 0, Some(2), SlotKind::Buffer).unwrap();
        assert_eq!(b.to_json(), r#"{"name":"GlobalUniforms","set":0,"binding":2,"slot_kind":"buffer","slot":2}"#);
    }

    #[test]
    fn non_canonical_texture_names_are_rejected_by_name() {
        let text = check_canonical_texture_name("g_Texture007").unwrap_err().to_string();
        assert!(text.contains("not a canonical g_TextureN binding name") && text.contains("g_Texture007"), "{text}");
        for ok in ["g_Texture0", "g_Texture10", "g_Texture1x", "u_Overlay", "g_Texture"] {
            assert!(check_canonical_texture_name(ok).is_ok(), "{ok}");
        }
        let text = BindingError::DuplicateTextureIndex { index: 1, first: "a".into(), second: "b".into() }.to_string();
        assert!(text.contains("`a`") && text.contains("`b`") && text.contains('1'));
    }

    fn res(name: &str, binding: u32, kind: SlotKind) -> ProgramResource {
        ProgramResource { name: name.to_string(), set: 0, binding: Some(binding), kind }
    }

    #[test]
    fn thirteen_textures_and_the_block_map_samplers_to_dense_slots() {
        let mut list = vec![res("GlobalUniforms", 13, SlotKind::Buffer)];
        for n in 0..13 {
            list.push(res(&format!("g_Texture{n}"), n, SlotKind::Texture));
            list.push(res(&format!("_we_Sampler_g_Texture{n}"), 14 + n, SlotKind::Sampler));
        }
        let map = assign_metal_slots(&list).unwrap();
        let find = |name: &str| map.iter().find(|b| b.name == name).unwrap();
        assert_eq!((find("GlobalUniforms").slot_kind, find("GlobalUniforms").slot), (SlotKind::Buffer, 13));
        for n in 0..13u32 {
            assert_eq!(find(&format!("g_Texture{n}")).slot, n);
            let s = find(&format!("_we_Sampler_g_Texture{n}"));
            assert_eq!((s.binding, s.slot), (14 + n, n));
        }
    }

    #[test]
    fn sixteen_samplers_fit_and_seventeen_name_the_limit() {
        let many = |n: u32| -> Vec<ProgramResource> { (0..n).map(|i| res(&format!("_we_Sampler_t{i}"), i, SlotKind::Sampler)).collect() };
        let ok = assign_metal_slots(&many(16)).unwrap();
        assert_eq!(ok.iter().map(|b| b.slot).max(), Some(15));
        let text = assign_metal_slots(&many(17)).unwrap_err().to_string();
        for needle in ["_we_Sampler_t16", "sampler slot 16", "argument-table limit of 15"] {
            assert!(text.contains(needle), "{needle}: {text}");
        }
    }

    #[test]
    fn a_sampler_shared_by_both_stages_has_one_slot() {
        let list = vec![res("_we_Sampler_a", 5, SlotKind::Sampler), res("_we_Sampler_b", 2, SlotKind::Sampler), res("_we_Sampler_a", 5, SlotKind::Sampler)];
        let map = assign_metal_slots(&list).unwrap();
        assert_eq!(map.len(), 2);
        assert_eq!(map.iter().find(|b| b.name == "_we_Sampler_b").unwrap().slot, 0);
        assert_eq!(map.iter().find(|b| b.name == "_we_Sampler_a").unwrap().slot, 1);
    }
}

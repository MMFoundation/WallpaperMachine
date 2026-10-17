// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The reflection model (spec 2.6.3, R41 to R52): what the engine must supply
//! for a program, merged canonically from the two stages.
//!
//! Descriptor-style fields (`set`, `descriptor`, `stages`, `count`) stay in the
//! schema although Metal has no descriptor sets, because the engine's reader
//! validates them (R96).

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use crate::json;
use crate::names::{MAX_TEXTURE_SLOT, SlotName, classify_slot_name};
use crate::request::StageKind;
use crate::text::{quote, sanitize};

/// Highest resource index and vertex location of the response schema as shipped (R36).
pub const MAX_RESOURCE_INDEX: u32 = 31;
pub const MAX_VERTEX_LOCATION: u32 = 31;

/// The descriptor kinds of the vocabulary. The order is the sort order of R43.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum DescriptorKind {
    UniformBuffer,
    SampledImage,
    /// Part of the vocabulary; the layer never emits it (R42).
    CombinedImageSampler,
    Sampler,
}

impl DescriptorKind {
    pub fn name(self) -> &'static str {
        match self {
            DescriptorKind::UniformBuffer => "uniform_buffer",
            DescriptorKind::SampledImage => "sampled_image",
            DescriptorKind::CombinedImageSampler => "combined_image_sampler",
            DescriptorKind::Sampler => "sampler",
        }
    }
}

/// The set of stages that use a resource.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct StageMask {
    vertex: bool,
    fragment: bool,
}

impl StageMask {
    pub const VERTEX: StageMask = StageMask { vertex: true, fragment: false };
    pub const FRAGMENT: StageMask = StageMask { vertex: false, fragment: true };
    pub const BOTH: StageMask = StageMask { vertex: true, fragment: true };

    pub fn of(kind: StageKind) -> StageMask {
        match kind {
            StageKind::Vertex => StageMask::VERTEX,
            StageKind::Fragment => StageMask::FRAGMENT,
        }
    }

    pub fn union(self, other: StageMask) -> StageMask {
        StageMask { vertex: self.vertex || other.vertex, fragment: self.fragment || other.fragment }
    }

    pub fn contains(self, kind: StageKind) -> bool {
        match kind {
            StageKind::Vertex => self.vertex,
            StageKind::Fragment => self.fragment,
        }
    }

    /// `"vertex"` then `"fragment"`, whichever are set (R42).
    pub fn names(self) -> Vec<&'static str> {
        let mut out = Vec::new();
        if self.vertex {
            out.push("vertex");
        }
        if self.fragment {
            out.push("fragment");
        }
        out
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DescriptorBinding {
    pub name: String,
    /// Always 0 (R42).
    pub set: u32,
    /// The resource index.
    pub binding: u32,
    pub descriptor: DescriptorKind,
    pub stages: StageMask,
    /// 1 for an ordinary resource, 0 for an unsized array. The engine refuses anything but 1.
    pub count: u32,
}

impl DescriptorBinding {
    pub fn to_json(&self) -> String {
        json::object(&[
            ("name", json::string(&self.name)),
            ("set", self.set.to_string()),
            ("binding", self.binding.to_string()),
            ("descriptor", json::string(self.descriptor.name())),
            ("stages", json::array(self.stages.names().into_iter().map(json::string))),
            ("count", self.count.to_string()),
        ])
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlockMember {
    pub name: String,
    /// Bytes from the start of the block.
    pub offset: u32,
    /// Bytes: the type's size, or stride times count for an array.
    pub size: u32,
    /// Scalar components of one element (1 scalar, 2 to 4 vector, 16 for mat4, 0 for a structure).
    pub element_count: u32,
    /// 0 when not an array.
    pub array_count: u32,
    /// Bytes between array elements, 0 when not an array.
    pub array_stride: u32,
}

impl BlockMember {
    pub fn to_json(&self) -> String {
        json::object(&[
            ("name", json::string(&self.name)),
            ("offset", self.offset.to_string()),
            ("size", self.size.to_string()),
            ("element_count", self.element_count.to_string()),
            ("array_count", self.array_count.to_string()),
            ("array_stride", self.array_stride.to_string()),
        ])
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UniformBlock {
    pub name: String,
    pub set: u32,
    pub binding: u32,
    pub size: u32,
    pub members: Vec<BlockMember>,
}

impl UniformBlock {
    pub fn to_json(&self) -> String {
        json::object(&[
            ("name", json::string(&self.name)),
            ("set", self.set.to_string()),
            ("binding", self.binding.to_string()),
            ("size", self.size.to_string()),
            ("members", json::array(self.members.iter().map(BlockMember::to_json))),
        ])
    }
}

/// The scalar type of a vertex input.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VertexScalar {
    Float,
    Uint,
    Sint,
}

/// A vertex input format: 32-bit float, unsigned or signed, one to four components (R50).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VertexFormat {
    scalar: VertexScalar,
    components: u8,
}

impl VertexFormat {
    /// `None` unless `components` is 1 to 4.
    pub fn new(scalar: VertexScalar, components: u8) -> Option<VertexFormat> {
        (1..=4).contains(&components).then_some(VertexFormat { scalar, components })
    }

    pub fn scalar(self) -> VertexScalar {
        self.scalar
    }

    pub fn components(self) -> u8 {
        self.components
    }

    /// `r32_sfloat`, `r32g32_uint`, `r32g32b32a32_sint`, and so on.
    pub fn name(self) -> String {
        let channels = ["r32", "g32", "b32", "a32"][..usize::from(self.components)].join("");
        let suffix = match self.scalar {
            VertexScalar::Float => "sfloat",
            VertexScalar::Uint => "uint",
            VertexScalar::Sint => "sint",
        };
        format!("{channels}_{suffix}")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VertexInput {
    /// The name the author wrote: the mesh supplies attributes under it (R50).
    pub name: String,
    pub location: u32,
    pub format: VertexFormat,
}

impl VertexInput {
    pub fn to_json(&self) -> String {
        json::object(&[
            ("name", json::string(&self.name)),
            ("location", self.location.to_string()),
            ("format", json::string(&self.format.name())),
        ])
    }
}

/// What the engine has to supply for a program, or for one of its stages.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Reflection {
    pub descriptor_bindings: Vec<DescriptorBinding>,
    pub uniform_blocks: Vec<UniformBlock>,
    pub vertex_inputs: Vec<VertexInput>,
    /// Ascending, no duplicates by construction; identical in the metadata document (R52).
    pub active_texture_slots: BTreeSet<u8>,
}

/// A problem found while building or merging reflection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReflectionError {
    OutsideLimits { name: String, set: u32, index: u32 },
    LocationOutOfRange { name: String, location: u32 },
    UnsupportedResource { name: String, what: String },
    ConflictingBlock { name: String, set: u32, binding: u32 },
    NonCanonicalTexture { name: String },
    TextureSlotOutOfRange { name: String, slot: u32 },
}

impl fmt::Display for ReflectionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            ReflectionError::OutsideLimits { name, set, index } => format!(
                "reflected resource metadata is outside shader model limits: resource {} in set {set} has index {index}, above the highest index {MAX_RESOURCE_INDEX}",
                quote(name)
            ),
            ReflectionError::LocationOutOfRange { name, location } => format!(
                "vertex input {} has location index {location}, which is out of range (the highest location is {MAX_VERTEX_LOCATION})",
                quote(name)
            ),
            ReflectionError::UnsupportedResource { name, what } => format!(
                "used resource {} is {what}, which the reflection document cannot express",
                quote(name)
            ),
            ReflectionError::ConflictingBlock { name, set, binding } => format!(
                "conflicting reflected uniform block layout for {} (set {set}, binding {binding})",
                quote(name)
            ),
            ReflectionError::NonCanonicalTexture { name } => {
                format!("{} is not a canonical g_TextureN binding name", quote(name))
            }
            ReflectionError::TextureSlotOutOfRange { name, slot } => format!(
                "texture {} names slot {slot}, outside the supported range 0 to {MAX_TEXTURE_SLOT}",
                quote(name)
            ),
        };
        f.write_str(&sanitize(&text))
    }
}

impl std::error::Error for ReflectionError {}

/// The material slot a used texture activates (R51): by name, never by binding
/// index. `Ok(None)` for names that are not material slots.
pub fn active_slot_for_texture(name: &str) -> Result<Option<u8>, ReflectionError> {
    match classify_slot_name(name) {
        SlotName::NotASlot => Ok(None),
        SlotName::NonCanonical => Err(ReflectionError::NonCanonicalTexture { name: name.to_string() }),
        SlotName::Canonical(n) if n > MAX_TEXTURE_SLOT => {
            Err(ReflectionError::TextureSlotOutOfRange { name: name.to_string(), slot: n })
        }
        SlotName::Canonical(n) => Ok(Some(n as u8)),
    }
}

impl Reflection {
    /// R36: used resources and vertex inputs must fit the schema's index limits.
    pub fn check_limits(&self) -> Result<(), ReflectionError> {
        for d in &self.descriptor_bindings {
            if d.binding > MAX_RESOURCE_INDEX {
                return Err(ReflectionError::OutsideLimits { name: d.name.clone(), set: d.set, index: d.binding });
            }
        }
        for b in &self.uniform_blocks {
            if b.binding > MAX_RESOURCE_INDEX {
                return Err(ReflectionError::OutsideLimits { name: b.name.clone(), set: b.set, index: b.binding });
            }
        }
        for v in &self.vertex_inputs {
            if v.location > MAX_VERTEX_LOCATION {
                return Err(ReflectionError::LocationOutOfRange { name: v.name.clone(), location: v.location });
            }
        }
        Ok(())
    }

    /// Merges the reflection of the stages into the program's canonical one (R43, R44).
    ///
    /// Descriptors are ordered by (set, binding, kind, name); an equal key from
    /// both stages becomes one entry with the union of stages and the larger
    /// count. Blocks are ordered by (set, binding, name); the same block with
    /// two different layouts is an error. Vertex inputs are ordered by
    /// location, active slots ascend. The index limits of R36 are checked.
    pub fn merge(parts: &[Reflection]) -> Result<Reflection, ReflectionError> {
        let mut descriptors: BTreeMap<(u32, u32, DescriptorKind, &str), DescriptorBinding> = BTreeMap::new();
        let mut blocks: BTreeMap<(u32, u32, &str), &UniformBlock> = BTreeMap::new();
        let mut inputs: BTreeMap<(u32, &str), VertexInput> = BTreeMap::new();
        let mut slots = BTreeSet::new();

        for part in parts {
            for d in &part.descriptor_bindings {
                descriptors
                    .entry((d.set, d.binding, d.descriptor, d.name.as_str()))
                    .and_modify(|merged| {
                        merged.stages = merged.stages.union(d.stages);
                        merged.count = merged.count.max(d.count);
                    })
                    .or_insert_with(|| d.clone());
            }
            for b in &part.uniform_blocks {
                match blocks.get(&(b.set, b.binding, b.name.as_str())) {
                    Some(existing) if **existing != *b => {
                        return Err(ReflectionError::ConflictingBlock {
                            name: b.name.clone(),
                            set: b.set,
                            binding: b.binding,
                        });
                    }
                    Some(_) => {}
                    None => {
                        blocks.insert((b.set, b.binding, b.name.as_str()), b);
                    }
                }
            }
            for v in &part.vertex_inputs {
                inputs.entry((v.location, v.name.as_str())).or_insert_with(|| v.clone());
            }
            slots.extend(part.active_texture_slots.iter().copied());
        }

        let merged = Reflection {
            descriptor_bindings: descriptors.into_values().collect(),
            uniform_blocks: blocks.into_values().cloned().collect(),
            vertex_inputs: inputs.into_values().collect(),
            active_texture_slots: slots,
        };
        merged.check_limits()?;
        Ok(merged)
    }

    /// The reflection document, keys in the order of spec 2.6.3.
    pub fn to_json(&self) -> String {
        json::object(&[
            ("descriptor_bindings", json::array(self.descriptor_bindings.iter().map(DescriptorBinding::to_json))),
            ("uniform_blocks", json::array(self.uniform_blocks.iter().map(UniformBlock::to_json))),
            ("vertex_inputs", json::array(self.vertex_inputs.iter().map(VertexInput::to_json))),
            ("active_texture_slots", json::array(self.active_texture_slots.iter().map(u8::to_string))),
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::Value;

    fn desc(name: &str, binding: u32, kind: DescriptorKind, stages: StageMask) -> DescriptorBinding {
        DescriptorBinding { name: name.into(), set: 0, binding, descriptor: kind, stages, count: 1 }
    }

    fn block(name: &str, binding: u32, member_offset: u32) -> UniformBlock {
        UniformBlock {
            name: name.into(),
            set: 0,
            binding,
            size: 16,
            members: vec![BlockMember {
                name: "u_X".into(),
                offset: member_offset,
                size: 4,
                element_count: 1,
                array_count: 0,
                array_stride: 0,
            }],
        }
    }

    fn input(name: &str, location: u32) -> VertexInput {
        VertexInput { name: name.into(), location, format: VertexFormat::new(VertexScalar::Float, 2).unwrap() }
    }

    fn as_object(text: &str) -> Vec<(String, Value)> {
        let Value::Object(m) = json::parse(text).unwrap() else { panic!("{text}") };
        m
    }

    #[test]
    fn empty_reflection_has_three_empty_arrays_and_the_slot_list() {
        assert_eq!(
            Reflection::default().to_json(),
            r#"{"descriptor_bindings":[],"uniform_blocks":[],"vertex_inputs":[],"active_texture_slots":[]}"#
        );
        assert_eq!(Reflection::merge(&[]).unwrap(), Reflection::default());
    }

    #[test]
    fn stage_masks_union_and_name_in_order() {
        assert_eq!(StageMask::VERTEX.union(StageMask::FRAGMENT), StageMask::BOTH);
        assert_eq!(StageMask::BOTH.names(), ["vertex", "fragment"]);
        assert_eq!(StageMask::FRAGMENT.names(), ["fragment"]);
        assert_eq!(StageMask::VERTEX.names(), ["vertex"]);
        assert!(StageMask::BOTH.contains(StageKind::Vertex) && !StageMask::FRAGMENT.contains(StageKind::Vertex));
        assert_eq!(StageMask::of(StageKind::Fragment), StageMask::FRAGMENT);
    }

    #[test]
    fn a_resource_used_by_both_stages_becomes_one_entry_with_both_stages() {
        let vertex = Reflection {
            descriptor_bindings: vec![desc("g_Texture0", 0, DescriptorKind::SampledImage, StageMask::VERTEX)],
            ..Reflection::default()
        };
        let mut fragment_binding = desc("g_Texture0", 0, DescriptorKind::SampledImage, StageMask::FRAGMENT);
        fragment_binding.count = 3;
        let fragment = Reflection { descriptor_bindings: vec![fragment_binding], ..Reflection::default() };
        let merged = Reflection::merge(&[vertex, fragment]).unwrap();
        assert_eq!(merged.descriptor_bindings.len(), 1);
        assert_eq!(merged.descriptor_bindings[0].stages, StageMask::BOTH);
        assert_eq!(merged.descriptor_bindings[0].count, 3, "the larger count wins");
    }

    #[test]
    fn descriptors_are_ordered_by_set_binding_kind_name_whatever_the_input_order() {
        let entries = vec![
            desc("z", 2, DescriptorKind::Sampler, StageMask::FRAGMENT),
            desc("b", 1, DescriptorKind::Sampler, StageMask::FRAGMENT),
            desc("a", 1, DescriptorKind::SampledImage, StageMask::FRAGMENT),
            desc("a", 1, DescriptorKind::UniformBuffer, StageMask::FRAGMENT),
            desc("c", 0, DescriptorKind::SampledImage, StageMask::VERTEX),
        ];
        let forward = Reflection { descriptor_bindings: entries.clone(), ..Reflection::default() };
        let mut reversed_entries = entries;
        reversed_entries.reverse();
        let reversed = Reflection { descriptor_bindings: reversed_entries, ..Reflection::default() };
        let a = Reflection::merge(std::slice::from_ref(&forward)).unwrap();
        let b = Reflection::merge(&[reversed]).unwrap();
        assert_eq!(a, b);
        let order: Vec<(&str, u32, DescriptorKind)> =
            a.descriptor_bindings.iter().map(|d| (d.name.as_str(), d.binding, d.descriptor)).collect();
        assert_eq!(
            order,
            [
                ("c", 0, DescriptorKind::SampledImage),
                ("a", 1, DescriptorKind::UniformBuffer),
                ("a", 1, DescriptorKind::SampledImage),
                ("b", 1, DescriptorKind::Sampler),
                ("z", 2, DescriptorKind::Sampler),
            ]
        );
    }

    #[test]
    fn the_same_name_and_binding_with_another_kind_is_a_second_entry() {
        let r = Reflection {
            descriptor_bindings: vec![
                desc("x", 1, DescriptorKind::SampledImage, StageMask::VERTEX),
                desc("x", 1, DescriptorKind::Sampler, StageMask::FRAGMENT),
            ],
            ..Reflection::default()
        };
        assert_eq!(Reflection::merge(&[r]).unwrap().descriptor_bindings.len(), 2);
    }

    #[test]
    fn identical_blocks_merge_and_conflicting_ones_fail_naming_block_set_and_binding() {
        let a = Reflection { uniform_blocks: vec![block("GlobalUniforms", 1, 0)], ..Reflection::default() };
        let b = a.clone();
        let merged = Reflection::merge(&[a.clone(), b]).unwrap();
        assert_eq!(merged.uniform_blocks.len(), 1);

        let other = Reflection { uniform_blocks: vec![block("GlobalUniforms", 1, 4)], ..Reflection::default() };
        let text = Reflection::merge(&[a, other]).unwrap_err().to_string();
        assert!(text.contains("conflicting reflected uniform block layout"), "{text}");
        assert!(text.contains("`GlobalUniforms`") && text.contains("set 0") && text.contains("binding 1"), "{text}");
    }

    #[test]
    fn blocks_are_ordered_by_set_binding_name() {
        let r = Reflection {
            uniform_blocks: vec![block("B", 2, 0), block("A", 2, 0), block("C", 0, 0)],
            ..Reflection::default()
        };
        let names: Vec<String> = Reflection::merge(&[r]).unwrap().uniform_blocks.into_iter().map(|b| b.name).collect();
        assert_eq!(names, ["C", "A", "B"]);
    }

    #[test]
    fn vertex_inputs_are_ordered_by_location_and_deduplicated() {
        let r = Reflection {
            vertex_inputs: vec![input("a_TexCoord", 1), input("a_Position", 0), input("a_Position", 0), input("a_Color", 2)],
            ..Reflection::default()
        };
        let merged = Reflection::merge(&[r]).unwrap();
        let names: Vec<&str> = merged.vertex_inputs.iter().map(|v| v.name.as_str()).collect();
        assert_eq!(names, ["a_Position", "a_TexCoord", "a_Color"]);
    }

    #[test]
    fn active_slots_union_ascending() {
        let a = Reflection { active_texture_slots: BTreeSet::from([5, 1]), ..Reflection::default() };
        let b = Reflection { active_texture_slots: BTreeSet::from([1, 0]), ..Reflection::default() };
        let merged = Reflection::merge(&[a, b]).unwrap();
        assert_eq!(merged.to_json(), r#"{"descriptor_bindings":[],"uniform_blocks":[],"vertex_inputs":[],"active_texture_slots":[0,1,5]}"#);
    }

    #[test]
    fn resource_index_above_31_fails_naming_resource_set_and_index() {
        let r = Reflection {
            descriptor_bindings: vec![desc("u_Late", 32, DescriptorKind::SampledImage, StageMask::FRAGMENT)],
            ..Reflection::default()
        };
        let text = Reflection::merge(&[r]).unwrap_err().to_string();
        assert!(text.contains("outside shader model limits"), "{text}");
        assert!(text.contains("`u_Late`") && text.contains("set 0") && text.contains("32"), "{text}");
        let ok = Reflection {
            descriptor_bindings: vec![desc("u_Edge", 31, DescriptorKind::SampledImage, StageMask::FRAGMENT)],
            ..Reflection::default()
        };
        assert!(Reflection::merge(&[ok]).is_ok());
    }

    #[test]
    fn vertex_location_above_31_fails_and_names_the_limit() {
        let r = Reflection { vertex_inputs: vec![input("a_Far", 32)], ..Reflection::default() };
        let text = Reflection::merge(&[r]).unwrap_err().to_string();
        assert!(text.contains("location index 32") && text.contains("out of range") && text.contains("31"), "{text}");
        assert!(text.contains("`a_Far`"));
        assert!(Reflection::merge(&[Reflection { vertex_inputs: vec![input("a_Edge", 31)], ..Reflection::default() }]).is_ok());
    }

    #[test]
    fn active_slots_come_from_names_not_binding_indices() {
        assert_eq!(active_slot_for_texture("g_Texture5"), Ok(Some(5)));
        assert_eq!(active_slot_for_texture("g_Texture0"), Ok(Some(0)));
        assert_eq!(active_slot_for_texture("g_Texture31"), Ok(Some(31)));
        assert_eq!(active_slot_for_texture("u_Overlay"), Ok(None));
        assert_eq!(active_slot_for_texture("_we_VideoChroma2"), Ok(None));
        assert_eq!(active_slot_for_texture("g_Texture1x"), Ok(None));
        let text = active_slot_for_texture("g_Texture007").unwrap_err().to_string();
        assert!(text.contains("not a canonical g_TextureN binding name"), "{text}");
        let text = active_slot_for_texture("g_Texture40").unwrap_err().to_string();
        assert!(text.contains("g_Texture40") && text.contains("40") && text.contains("31"), "{text}");
        assert!(active_slot_for_texture("g_Texture300").is_err());
    }

    #[test]
    fn vertex_formats_are_named_by_channels_and_type() {
        use VertexScalar::*;
        let cases = [
            (Float, 1, "r32_sfloat"), (Float, 2, "r32g32_sfloat"), (Float, 3, "r32g32b32_sfloat"),
            (Float, 4, "r32g32b32a32_sfloat"), (Uint, 1, "r32_uint"), (Uint, 4, "r32g32b32a32_uint"),
            (Sint, 2, "r32g32_sint"), (Sint, 3, "r32g32b32_sint"),
        ];
        for (scalar, n, name) in cases {
            assert_eq!(VertexFormat::new(scalar, n).unwrap().name(), name);
        }
        assert!(VertexFormat::new(Float, 0).is_none() && VertexFormat::new(Float, 5).is_none());
    }

    #[test]
    fn the_document_is_compact_with_keys_in_the_documented_order() {
        let r = Reflection {
            descriptor_bindings: vec![desc("GlobalUniforms", 1, DescriptorKind::UniformBuffer, StageMask::BOTH)],
            uniform_blocks: vec![block("GlobalUniforms", 1, 0)],
            vertex_inputs: vec![input("a_Position", 0)],
            active_texture_slots: BTreeSet::from([0]),
        };
        let text = r.to_json();
        assert!(!text.contains(' ') && !text.contains('\n'));
        let top: Vec<String> = as_object(&text).into_iter().map(|(k, _)| k).collect();
        assert_eq!(top, ["descriptor_bindings", "uniform_blocks", "vertex_inputs", "active_texture_slots"]);
        assert!(text.contains(r#"{"name":"GlobalUniforms","set":0,"binding":1,"descriptor":"uniform_buffer","stages":["vertex","fragment"],"count":1}"#));
        assert!(text.contains(r#""uniform_blocks":[{"name":"GlobalUniforms","set":0,"binding":1,"size":16,"members":[{"name":"u_X","offset":0,"size":4,"element_count":1,"array_count":0,"array_stride":0}]}]"#));
        assert!(text.contains(r#""vertex_inputs":[{"name":"a_Position","location":0,"format":"r32g32_sfloat"}]"#));
        assert!(text.ends_with(r#""active_texture_slots":[0]}"#));
    }

    #[test]
    fn descriptor_vocabulary() {
        let kinds = [
            (DescriptorKind::UniformBuffer, "uniform_buffer"),
            (DescriptorKind::SampledImage, "sampled_image"),
            (DescriptorKind::CombinedImageSampler, "combined_image_sampler"),
            (DescriptorKind::Sampler, "sampler"),
        ];
        for (kind, name) in kinds {
            assert_eq!(kind.name(), name);
        }
    }

    #[test]
    fn unsupported_resources_name_the_resource() {
        let text = ReflectionError::UnsupportedResource { name: "u_Buf".into(), what: "a storage buffer".into() }.to_string();
        assert!(text.contains("`u_Buf`") && text.contains("storage buffer"), "{text}");
    }
}

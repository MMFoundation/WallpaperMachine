// Clean-room implementation from the WallpaperMachine spec p5-models-puppets.md; written without access to the original source.
#include "WPMdlParser.hpp"

#include <algorithm>
#include <cstring>
#include <limits>
#include <string>

#include "SpecTexs.hpp"
#include "WPShaderParser.hpp"
#include "Scene/SceneIndexArray.h"
#include "Utils/Logging.h"
#include "wpscene/WPMaterial.h"

using namespace wallpaper;

namespace
{
using Range = SceneMesh::DrawRange;

// Vertices are converted in slices so the interleaved copy never needs more
// than one slice of scratch memory next to the final buffer.
constexpr usize kSliceVertices = 8192;

constexpr std::string_view kMaskTarget = "_rt_puppet_mask";

// The one draw range that draws nothing.
std::vector<Range> NoDraw() { return { Range { 0, 0 } }; }

// The draw range of one part when it lies wholly inside the index array.
bool PartRange(const WPMdl::Mesh::Part& part, uint64_t total, Range& out) {
    if (part.size == 0) return false;
    const uint64_t start = part.start;
    const uint64_t end   = start + static_cast<uint64_t>(part.size); // cannot overflow 64 bits
    if (start > total || end > total) return false;
    out = Range { part.start, part.size };
    return true;
}

uint64_t TotalIndices(const WPMdl::Mesh& src) { return static_cast<uint64_t>(src.indices.size()) * 3u; }

// Ranges of the parts whose position in the table `wanted` accepts; nothing
// valid left means the single range that draws nothing.
template<typename Wanted>
std::vector<Range> CollectRanges(const WPMdl::Mesh& src, Wanted&& wanted) {
    std::vector<Range> ranges;
    const uint64_t     total = TotalIndices(src);
    for (usize pos = 0; pos < src.parts.size(); pos++) {
        Range range;
        if (wanted(pos) && PartRange(src.parts[pos], total, range)) ranges.push_back(range);
    }
    if (ranges.empty()) return NoDraw();
    return ranges;
}

template<typename T, usize N>
void Put(float* row, usize offset, const std::vector<std::array<T, N>>& stream, usize vertex,
         const std::array<T, N>& fallback) {
    const auto& value = vertex < stream.size() ? stream[vertex] : fallback;
    std::memcpy(row + offset, value.data(), sizeof(T) * N);
}

static_assert(sizeof(float) == sizeof(uint32_t));
} // namespace

bool WPMdlParser::Parse(std::string_view, fs::VFS&, WPMdl&) {
    // CLEANROOM LM1
    return false;
}

void WPMdlParser::GenMeshFromMdl(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src) {
    if (src.positions.empty()) return;
    const usize vertex_count = src.positions.size();

    const bool has_uv      = ! src.texcoords.empty();
    const bool has_normal  = ! src.normals.empty();
    const bool has_tangent = ! src.tangents.empty();
    const bool has_skin    = ! src.blend_indices.empty();

    std::vector<SceneVertexArray::SceneVertexAttribute> attrs;
    attrs.push_back({ std::string(WE_IN_POSITION), VertexType::FLOAT3 });
    if (has_uv) attrs.push_back({ std::string(WE_IN_TEXCOORD), VertexType::FLOAT2 });
    if (has_normal) attrs.push_back({ std::string(WE_IN_NORMAL), VertexType::FLOAT3 });
    if (has_tangent) attrs.push_back({ std::string(WE_IN_TANGENT), VertexType::FLOAT4 });
    if (has_skin) {
        attrs.push_back({ std::string(WE_IN_BLENDINDICES), VertexType::UINT4 });
        attrs.push_back({ std::string(WE_IN_BLENDWEIGHTS), VertexType::FLOAT4 });
    }

    // Where each stream sits inside one vertex record, in floats.
    std::vector<usize> offsets;
    usize              stride = 0;
    for (const auto& attr : attrs) {
        offsets.push_back(stride);
        stride += SceneVertexArray::RealAttributeSize(attr);
    }

    SceneVertexArray vertices(attrs, vertex_count);
    std::vector<float> slice;
    slice.reserve(std::min(vertex_count, kSliceVertices) * stride);
    for (usize begin = 0; begin < vertex_count; begin += kSliceVertices) {
        const usize end = std::min(vertex_count, begin + kSliceVertices);
        slice.assign((end - begin) * stride, 0.0f);
        for (usize v = begin; v < end; v++) {
            float* row = slice.data() + (v - begin) * stride;
            usize  at  = 0;
            Put<float, 3>(row, offsets[at++], src.positions, v, { 0.0f, 0.0f, 0.0f });
            if (has_uv) Put<float, 2>(row, offsets[at++], src.texcoords, v, { 0.0f, 0.0f });
            if (has_normal) Put<float, 3>(row, offsets[at++], src.normals, v, { 0.0f, 0.0f, 1.0f });
            if (has_tangent) {
                Put<float, 4>(row, offsets[at++], src.tangents, v, { 1.0f, 0.0f, 0.0f, 1.0f });
            }
            if (has_skin) {
                // Bone numbers travel as integers: copied bit for bit, never as floats.
                Put<uint32_t, 4>(row, offsets[at++], src.blend_indices, v, { 0u, 0u, 0u, 0u });
                if (src.blend_weights.empty()) {
                    row[offsets[at]] = 1.0f;
                } else {
                    Put<float, 4>(row, offsets[at], src.blend_weights, v, { 0.0f, 0.0f, 0.0f, 0.0f });
                }
            }
        }
        vertices.SetVertexs(begin, slice);
    }
    submesh.AddVertexArray(std::move(vertices));

    // Indices: 16 bits unless one of them cannot be named in 16.
    const usize triangles = src.indices.size();
    if (triangles == 0) {
        const std::array<uint32_t, 1> placeholder { 0u };
        SceneIndexArray               array(std::span<const uint32_t>(placeholder.data(), 1));
        array.SetDrawIndexCount(0);
        submesh.AddIndexArray(std::move(array));
    } else {
        uint32_t largest = 0;
        for (const auto& triangle : src.indices) {
            largest = std::max({ largest, triangle[0], triangle[1], triangle[2] });
        }
        const bool wide  = largest > 0xFFFFu;
        const usize quads = (triangles + 1) / 2; // capacity is counted in quads of six indices
        SceneIndexArray array(quads, wide ? SceneIndexWidth::UInt32 : SceneIndexWidth::UInt16);
        static_assert(sizeof(std::array<uint32_t, 3>) == 3 * sizeof(uint32_t));
        if (wide) {
            array.Assign(0, std::span<const uint32_t>(src.indices[0].data(), triangles * 3));
        } else {
            std::vector<uint16_t> narrow;
            const usize           slice_triangles = 4096;
            narrow.reserve(slice_triangles * 3);
            for (usize begin = 0; begin < triangles; begin += slice_triangles) {
                const usize end = std::min(triangles, begin + slice_triangles);
                narrow.clear();
                for (usize t = begin; t < end; t++) {
                    for (const uint32_t index : src.indices[t]) {
                        narrow.push_back(static_cast<uint16_t>(index));
                    }
                }
                array.AssignHalf(begin * 3, narrow);
            }
        }
        submesh.AddIndexArray(std::move(array));
    }

    if (! src.parts.empty()) submesh.SetDrawRanges(CollectRanges(src, [](usize) { return true; }));
}

void WPMdlParser::GenMaskSubmeshFromMdl(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src,
                                        std::span<const uint32_t> part_indices) {
    GenMeshFromMdl(submesh, src);
    // The entries are positions in the parts table; each part is drawn once.
    std::vector<bool> chosen(src.parts.size(), false);
    for (const uint32_t position : part_indices) {
        if (position < chosen.size()) chosen[position] = true;
    }
    submesh.SetDrawRanges(CollectRanges(src, [&](usize pos) { return chosen[pos]; }));
}

void WPMdlParser::GenPuppetMesh(SceneMesh& mesh, const WPMdl& mdl, const bool include_masks) {
    auto& submeshes = mesh.Submeshes();
    submeshes.clear();
    uint32_t slot = 0;
    for (const auto& src : mdl.meshes) {
        if (src.positions.empty()) continue;

        submeshes.emplace_back();
        GenMeshFromMdl(submeshes.back(), src);
        submeshes.back().material_slot = slot++;
        if (! include_masks || src.masks.empty()) continue;

        // The base draw leaves out the pieces a mask clips; those come back in
        // their own, clipped, submesh below.
        std::vector<bool> clipped(src.parts.size(), false);
        bool              any = false;
        for (const auto& mask : src.masks) {
            for (const uint32_t position : mask.part_ids_a) {
                if (position < clipped.size()) {
                    clipped[position] = true;
                    any               = true;
                }
            }
        }
        if (any) {
            submeshes.back().SetDrawRanges(
                CollectRanges(src, [&](usize pos) { return ! clipped[pos]; }));
        }

        for (const auto& mask : src.masks) {
            submeshes.emplace_back();
            GenMaskSubmeshFromMdl(submeshes.back(), src, mask.part_ids_b);
            submeshes.back().material_slot   = slot++;
            submeshes.back().output_override = std::string(kMaskTarget);

            submeshes.emplace_back();
            GenMaskSubmeshFromMdl(submeshes.back(), src, mask.part_ids_a);
            submeshes.back().material_slot = slot++;
        }
    }
}

void WPMdlParser::AddPuppetShaderInfo(WPShaderInfo& info, const WPMdl& mdl) {
    if (mdl.puppet == nullptr || mdl.puppet->bones.empty()) return;
    info.combos["SKINNING"] = "1";
    info.combos["BONECOUNT"] = std::to_string(mdl.puppet->bones.size());
}

void WPMdlParser::AddPuppetMatInfo(wpscene::WPMaterial& mat, const WPMdl& mdl) {
    if (mdl.puppet == nullptr || mdl.puppet->bones.empty()) return;
    mat.combos["SKINNING"]  = 1;
    mat.combos["BONECOUNT"] = static_cast<int32_t>(mdl.puppet->bones.size());
    mat.use_puppet          = true;
}

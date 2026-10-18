#pragma once
#include <vector>
#include <memory>
#include <cstddef>
#include <cstdint>
#include <climits>
#include <atomic>
#include <span>
#include <string>

#include "SceneVertexArray.h"
#include "SceneIndexArray.h"
#include "SceneMaterial.h"

namespace wallpaper
{

/// What rewrites a mesh's vertices, which is not the same question as whether
/// they can be rewritten at all.
///
/// `Dynamic()` -- the old single bit -- answers "may this geometry change after
/// parsing", which every consumer of a vertex buffer needs. It does not answer
/// "does this geometry change on its own", and the two were the same value for
/// as long as a particle system was the only thing that rewrote a mesh. A text
/// card is rewritten too, but only when something re-lays the text out, so a
/// scene holding one is not a scene that has to keep drawing.
enum class MeshUpdate : uint8_t {
	/// Written once while parsing and never again.
	Fixed = 0,
	/// Rewritten every frame by something that advances on its own -- a
	/// particle system. A scene holding one always has work to do.
	PerFrame = 1,
	/// Rewritten only when an event re-lays it out, and unchanged in between.
	/// Still uploaded through the dynamic path, still never reusable by the
	/// pixel cache; simply not a reason for the clock to keep running.
	OnEvent = 2,
};

class SceneMesh {
public:
	struct DrawRange {
		uint32_t indexOffset {0};
		uint32_t indexCount {0};
	};

	class Submesh {
	public:
		std::size_t VertexCount() const {
			// CLEANROOM SM19
			return 0;
		}
		std::size_t IndexCount() const {
			// CLEANROOM SM19
			return 0;
		}

		const SceneVertexArray& GetVertexArray(const std::size_t index) const {
			// CLEANROOM SM19
			(void)index;
			static const SceneVertexArray none({}, 0);
			return none;
		}
		const SceneIndexArray& GetIndexArray(const std::size_t index) const {
			// CLEANROOM SM19
			(void)index;
			static const SceneIndexArray none(std::span<const uint32_t> {});
			return none;
		}

		SceneVertexArray& GetVertexArray(const std::size_t index) {
			// CLEANROOM SM19
			(void)index;
			static SceneVertexArray none({}, 0);
			return none;
		}
		SceneIndexArray& GetIndexArray(const std::size_t index) {
			// CLEANROOM SM19
			(void)index;
			static SceneIndexArray none(std::span<const uint32_t> {});
			return none;
		}

		void AddIndexArray(SceneIndexArray&& array) {
			// CLEANROOM SM19
			(void)array;
		}
		void AddVertexArray(SceneVertexArray&& array) {
			// CLEANROOM SM19
			(void)array;
		}

		const std::vector<DrawRange>& DrawRanges() const {
			// CLEANROOM SM19
			static const std::vector<DrawRange> none;
			return none;
		}
		std::vector<DrawRange>& DrawRanges() {
			// CLEANROOM SM19
			static std::vector<DrawRange> none;
			return none;
		}
		void SetDrawRanges(std::span<const DrawRange> ranges) {
			// CLEANROOM SM19
			(void)ranges;
		}

		uint32_t material_slot {0};
		std::string output_override;
	};

	explicit SceneMesh(MeshUpdate update = MeshUpdate::Fixed):m_update(update) {
		// CLEANROOM SM19
	}

	std::size_t VertexCount() const {
		// CLEANROOM SM19
		return 0;
	}
	std::size_t IndexCount() const {
		// CLEANROOM SM19
		return 0;
	}

	MeshPrimitive Primitive() const {
		// CLEANROOM SM19
		return MeshPrimitive::TRIANGLE;
	}
	uint32_t PointSize() const {
		// CLEANROOM SM19
		return 1;
	}

	/// Whether the vertices may be rewritten after parsing. Every upload,
	/// buffer-allocation and pixel-reuse decision asks this and nothing else.
	bool Dynamic() const { return m_update != MeshUpdate::Fixed; }
	/// What rewrites them. Ask this only when the answer changes whether the
	/// scene has to keep drawing; never to decide how to upload.
	MeshUpdate UpdateDriver() const { return m_update; }
	bool UpdatesOnEvent() const { return m_update == MeshUpdate::OnEvent; }
	const auto& Dirty() const {
		// CLEANROOM SM19
		static const std::atomic<bool> none { false };
		return none;
	}
	auto& Dirty() {
		// CLEANROOM SM19
		static std::atomic<bool> none { false };
		return none;
	}
	void SetDirty() {
		// CLEANROOM SM19
	}
	uint64_t DirtyGeneration() const {
		// CLEANROOM SM19
		return 0;
	}

	uint32_t ID() const {
		// CLEANROOM SM19
		return 0;
	}
	void SetID(uint32_t v) {
		// CLEANROOM SM19
		(void)v;
	}

	const SceneVertexArray& GetVertexArray(const std::size_t index) const {
		// CLEANROOM SM19
		(void)index;
		static const SceneVertexArray none({}, 0);
		return none;
	}
	const SceneIndexArray& GetIndexArray(const std::size_t index) const {
		// CLEANROOM SM19
		(void)index;
		static const SceneIndexArray none(std::span<const uint32_t> {});
		return none;
	}

	SceneVertexArray& GetVertexArray(const std::size_t index) {
		// CLEANROOM SM19
		(void)index;
		static SceneVertexArray none({}, 0);
		return none;
	}
	SceneIndexArray& GetIndexArray(const std::size_t index) {
		// CLEANROOM SM19
		(void)index;
		static SceneIndexArray none(std::span<const uint32_t> {});
		return none;
	}

	void AddIndexArray(SceneIndexArray&& array) {
		// CLEANROOM SM19
		(void)array;
	}
	void AddVertexArray(SceneVertexArray&& array) {
		// CLEANROOM SM19
		(void)array;
	}
	void AddMaterial(SceneMaterial&& material) {
		// CLEANROOM SM19
		(void)material;
	}

	void SetPrimitive(MeshPrimitive v) {
		// CLEANROOM SM19
		(void)v;
	}
	void SetPointSize(uint32_t v) {
		// CLEANROOM SM19
		(void)v;
	}

	SceneMaterial* Material() {
		// CLEANROOM SM19
		return nullptr;
	}
	const SceneMaterial* Material() const {
		// CLEANROOM SM19
		return nullptr;
	}
	SceneMaterial* MaterialForSlot(uint32_t slot) {
		// CLEANROOM SM19
		(void)slot;
		return nullptr;
	}
	const SceneMaterial* MaterialForSlot(uint32_t slot) const {
		// CLEANROOM SM19
		(void)slot;
		return nullptr;
	}

	const std::vector<Submesh>& Submeshes() const {
		// CLEANROOM SM19
		static const std::vector<Submesh> none;
		return none;
	}
	std::vector<Submesh>& Submeshes() {
		// CLEANROOM SM19
		static std::vector<Submesh> none;
		return none;
	}

	const std::vector<std::shared_ptr<SceneMaterial>>& MaterialSlots() const {
		// CLEANROOM SM19
		static const std::vector<std::shared_ptr<SceneMaterial>> none;
		return none;
	}
	std::vector<std::shared_ptr<SceneMaterial>>& MaterialSlots() {
		// CLEANROOM SM19
		static std::vector<std::shared_ptr<SceneMaterial>> none;
		return none;
	}
	std::shared_ptr<SceneMaterial> MaterialSlotPtr(std::size_t index = 0) const {
		// CLEANROOM SM19
		(void)index;
		return nullptr;
	}

	const std::vector<DrawRange>& DrawRanges() const {
		// CLEANROOM SM19
		static const std::vector<DrawRange> none;
		return none;
	}
	std::vector<DrawRange>& DrawRanges() {
		// CLEANROOM SM19
		static std::vector<DrawRange> none;
		return none;
	}
	void SetDrawRanges(std::span<const DrawRange> ranges) {
		// CLEANROOM SM19
		(void)ranges;
	}

	void ChangeMeshDataFrom(const SceneMesh& o) {
		// CLEANROOM SM19
		(void)o;
	}

private:
	MeshUpdate m_update;
};

}

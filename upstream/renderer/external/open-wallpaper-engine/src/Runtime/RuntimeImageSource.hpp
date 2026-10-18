#pragma once

#include "Interface/IImageParser.h"
#include "Runtime/MediaArtwork.hpp"

#include <atomic>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>

namespace wallpaper
{

class RuntimeImageSource final : public IImageParser {
public:
    explicit RuntimeImageSource(std::unique_ptr<IImageParser> fallback) {
        // CLEANROOM RT12
        (void)fallback;
    }

    std::shared_ptr<Image> Parse(const std::string& name) override {
        // CLEANROOM RT13
        (void)name;
        return nullptr;
    }

    ImageHeader ParseHeader(const std::string& name) override {
        // CLEANROOM RT13
        (void)name;
        return ImageHeader {};
    }

    void SetTextureSurfaceSize(uint32_t width, uint32_t height) override {
        // CLEANROOM RT13
        (void)width;
        (void)height;
    }

    bool IsRuntimeImage(const std::string& name) const {
        // CLEANROOM RT12
        (void)name;
        return false;
    }

    /// Changes whenever a name joins or leaves this source (`RemoveImage`,
    /// `BindCoverSlot`).
    ///
    /// Lock-free, so a renderer can keep its per-slot `IsRuntimeImage` answers
    /// and only ask again when this moves.
    uint64_t NamesGeneration() const { return m_names_generation.load(std::memory_order_acquire); }

    /// How many times this name has been given new pixels, or zero when it
    /// never has.
    ///
    /// Monotonic per name and readable without taking a copy of the image, so a
    /// renderer can ask "is what I uploaded still current?" every frame without
    /// hashing pixels. The same number is what `Image::key` carries, so the two
    /// can never disagree.
    uint64_t Version(const std::string& name) const {
        // CLEANROOM RT12
        (void)name;
        return 0;
    }

    /// Whether `name` already holds exactly these pixels.
    ///
    /// Republishing an identical image is not free and not neutral: it retires
    /// the texture the GPU is sampling, allocates and uploads another, and —
    /// for a cover — moves the current image into `$mediaPreviousThumbnail`,
    /// which is what a wallpaper cross-fades *from*, so a replay would fade a
    /// cover into itself. Replays are normal: every new scene handle is sent
    /// the current cover again. One comparison against bytes already in memory
    /// is cheaper than any of that.
    bool MatchesRgba(const std::string& name, uint32_t width, uint32_t height,
                     const uint8_t* rgba, std::size_t rgba_len) const {
        // CLEANROOM RT12
        (void)name;
        (void)width;
        (void)height;
        (void)rgba;
        (void)rgba_len;
        return false;
    }

    void SetRgbaImage(std::string name, uint32_t width, uint32_t height, const uint8_t* rgba,
                      std::size_t rgba_len) {
        // CLEANROOM RT12
        (void)name;
        (void)width;
        (void)height;
        (void)rgba;
        (void)rgba_len;
    }

    /// Forgets the pixels given to `name`, for an image whose owner is gone (the
    /// text layer a script made and destroyed), so images made and dropped over
    /// and over do not accumulate. Only a render graph built without the owner
    /// may call this: until then it still samples the image. The two cover slots
    /// (`$`-names) are the source's own and are never removed. Answers whether
    /// there was anything to remove.
    bool RemoveImage(const std::string& name) {
        if (name.empty() || name.front() == '$') return false;
        std::lock_guard lock(m_mutex);
        if (m_runtime_images.erase(name) == 0) return false;
        m_versions.erase(name);
        m_names_generation.fetch_add(1, std::memory_order_release);
        return true;
    }

    /// Publishes what `from` currently holds under `to`, without copying pixels.
    ///
    /// `SetRgbaImage` builds a fresh immutable `Image` every time, so two names
    /// may share one: replacing `from` afterwards leaves `to` holding exactly
    /// what `from` used to be. `to` inherits `from`'s version so the number and
    /// the `Image::key` it is taken from keep agreeing, and it still only ever
    /// rises because `from`'s own version does.
    ///
    /// Returns false when `from` has never been given pixels.
    bool AliasRuntimeImage(const std::string& from, const std::string& to) {
        // CLEANROOM RT12
        (void)from;
        (void)to;
        return false;
    }

    /// Binds a texture slot that asks for a cover to the picture its author left
    /// in that slot, and returns the name the slot samples.
    ///
    /// A cover layer ships its own art in the slot (the wallpaper's default
    /// cover) and names `$mediaThumbnail` or `$mediaPreviousThumbnail` as what
    /// the runtime puts there. Wallpaper Engine keeps the authored picture
    /// until there is a cover to show, so a layer that has nothing playing shows
    /// its art rather than the 1x1 transparent texel those names start as. The
    /// returned name shows the cover while one is published and the authored
    /// picture while it is not -- before the first track, and again after the
    /// explicit clear. It is an ordinary runtime image to a renderer
    /// (`IsRuntimeImage`, `Version`, `Parse`), so a track change swaps it on the
    /// next frame without a graph rebuild and an idle slot costs the integer
    /// version check it already did.
    ///
    /// The cover's own name comes back unchanged when there is nothing to stand
    /// in: no authored name, a picture this source cannot read, one that is a
    /// video or a sprite sheet, or one whose format the cover does not share
    /// (a mask or a normal map: the shader a material is compiled with reads
    /// its channels differently from a cover's, `ApplyTextureFormatCombo`). The
    /// authored picture is decoded the first time a renderer asks for it, not
    /// here, so a texture budget set after the scene parsed still applies to
    /// it, and stays resident after that so a clear does not decode it again.
    std::string BindCoverSlot(const std::string& cover_name, const std::string& authored_name) {
        // CLEANROOM RT13
        (void)authored_name;
        return cover_name;
    }

private:
    /// One slot bound by `BindCoverSlot`.
    struct CoverSlot {
        /// The cover name whose image the slot shows once there is one.
        std::string            cover;
        std::string            authored_name;
        /// The authored picture's header, read when the slot was bound.
        ImageHeader            header;
        /// The authored picture, decoded on first need.
        std::shared_ptr<Image> authored;
        /// The picture could not be decoded: the slot shows the cover's own
        /// image, transparent while idle, as it did before slots existed.
        bool                   authored_failed { false };
    };

    static bool IsCoverName(const std::string& name) {
        return name == "$mediaThumbnail" || name == "$mediaPreviousThumbnail";
    }

    /// What the cover names hold when no track does: one transparent texel,
    /// which is also what an explicit clear publishes.
    static bool IsEmptyCoverPixel(uint32_t width, uint32_t height, uint8_t alpha) {
        return width == 1 && height == 1 && alpha == 0;
    }

    static bool IsEmptyCover(const Image& image) {
        if (image.header.width != 1 || image.header.height != 1 || image.slots.empty()) {
            return false;
        }
        const auto& mipmaps = image.slots.front().mipmaps;
        return ! mipmaps.empty() && mipmaps.front().data != nullptr &&
               mipmaps.front().size >= 4 &&
               IsEmptyCoverPixel(1, 1, mipmaps.front().data.get()[3]);
    }

    /// The formats a cover can stand in for: colour pictures, which a shader
    /// reads the same way whether the slot holds the art or a track's RGBA.
    static bool IsColourPicture(TextureFormat format) {
        return format == TextureFormat::RGBA8 || format == TextureFormat::BC1 ||
               format == TextureFormat::BC2 || format == TextureFormat::BC3;
    }

    /// The image a cover name holds when it holds a track's cover, not the
    /// empty one. Caller holds the lock.
    std::shared_ptr<Image> RealCoverLocked(const CoverSlot& slot) const {
        const auto cover = m_runtime_images.find(slot.cover);
        if (cover == m_runtime_images.end() || cover->second == nullptr ||
            IsEmptyCover(*cover->second)) {
            return nullptr;
        }
        return cover->second;
    }

    std::shared_ptr<Image> PlaceholderLocked(const CoverSlot& slot) const {
        const auto cover = m_runtime_images.find(slot.cover);
        return cover == m_runtime_images.end() ? nullptr : cover->second;
    }

    /// Decodes a slot's authored picture the first time it is needed. Outside
    /// the lock: it reads a file, and a renderer asks about versions every
    /// frame. Two threads asking at once both decode and one result is kept.
    std::shared_ptr<Image> ParseAuthoredForSlot(const std::string& slot_name,
                                                const std::string& authored_name) {
        auto decoded = m_fallback != nullptr ? m_fallback->Parse(authored_name) : nullptr;
        if (decoded != nullptr &&
            (decoded->header.isVideo || decoded->slots.empty() ||
             decoded->slots.front().mipmaps.empty())) {
            decoded = nullptr;
        }
        std::lock_guard lock(m_mutex);
        const auto      slot = m_cover_slots.find(slot_name);
        if (slot == m_cover_slots.end()) return decoded;
        if (slot->second.authored == nullptr && decoded != nullptr) {
            slot->second.authored = std::move(decoded);
        }
        slot->second.authored_failed = slot->second.authored == nullptr;
        // What the slot shows now: a cover may have arrived while this decoded.
        if (auto cover = RealCoverLocked(slot->second); cover != nullptr) return cover;
        return slot->second.authored != nullptr ? slot->second.authored
                                                : PlaceholderLocked(slot->second);
    }

    mutable std::mutex                                      m_mutex;
    std::unique_ptr<IImageParser>                           m_fallback;
    std::unordered_map<std::string, std::shared_ptr<Image>> m_runtime_images;
    std::unordered_map<std::string, CoverSlot>              m_cover_slots;
    std::unordered_map<std::string, uint64_t>               m_versions;
    std::atomic<uint64_t>                                   m_names_generation { 0 };
};

/// Publishes one now-playing cover, and reports whether anything changed.
///
/// The cover being replaced becomes `$mediaPreviousThumbnail`, which is what a
/// wallpaper cross-fades from, so it has to be captured before the new pixels
/// land. One definition, because the renderer and the offscreen probe must
/// publish covers the same way.
///
/// Returns false when the cover on screen is already exactly this one, so a
/// caller can skip the work a change would have needed.
inline bool PublishSystemMediaArtwork(RuntimeImageSource& source, uint32_t width, uint32_t height,
                                      const uint8_t* rgba, std::size_t rgba_len) {
    if (! IsValidSystemMediaArtwork(width, height, rgba, rgba_len)) return false;
    if (IsClearSystemMediaArtwork(width, height, rgba_len)) {
        constexpr std::array<uint8_t, 4> transparent {};
        if (source.MatchesRgba("$mediaThumbnail", 1, 1, transparent.data(), transparent.size()) &&
            source.MatchesRgba("$mediaPreviousThumbnail", 1, 1, transparent.data(), transparent.size())) return false;
        source.SetRgbaImage("$mediaThumbnail", 1, 1, transparent.data(), transparent.size());
        return true;
    }
    if (source.MatchesRgba("$mediaThumbnail", width, height, rgba, rgba_len)) return false;
    source.AliasRuntimeImage("$mediaThumbnail", "$mediaPreviousThumbnail");
    source.SetRgbaImage("$mediaThumbnail", width, height, rgba, rgba_len);
    return true;
}

} // namespace wallpaper

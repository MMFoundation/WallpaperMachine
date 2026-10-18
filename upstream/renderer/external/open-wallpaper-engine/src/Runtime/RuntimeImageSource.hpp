// Clean-room implementation from the WallpaperMachine spec e2-runtime-animation.md; written without access to the original source.
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
    explicit RuntimeImageSource(std::unique_ptr<IImageParser> fallback) :
        m_fallback(std::move(fallback)) {
        // Both cover names exist from the start, as one transparent texel, so a layer that binds
        // one finds an image on its very first parse.
        constexpr std::array<uint8_t, 4> transparent {};
        std::lock_guard                  lock(m_mutex);
        for (const char* cover : { "$mediaThumbnail", "$mediaPreviousThumbnail" }) {
            const auto made = MakeImageLocked(cover, 1, 1, transparent.data(), transparent.size());
            PublishLocked(cover, made.image, made.version);
        }
    }

    std::shared_ptr<Image> Parse(const std::string& name) override {
        std::string authored_name;
        {
            std::lock_guard lock(m_mutex);
            if (const auto image = m_runtime_images.find(name); image != m_runtime_images.end()) {
                return image->second;
            }
            if (const auto slot = m_cover_slots.find(name); slot != m_cover_slots.end()) {
                if (auto cover = RealCoverLocked(slot->second); cover != nullptr) return cover;
                if (slot->second.authored != nullptr) return slot->second.authored;
                if (slot->second.authored_failed) return PlaceholderLocked(slot->second);
                authored_name = slot->second.authored_name;
            }
        }
        if (! authored_name.empty()) return ParseAuthoredForSlot(name, authored_name);
        return m_fallback != nullptr ? m_fallback->Parse(name) : nullptr;
    }

    ImageHeader ParseHeader(const std::string& name) override {
        {
            std::lock_guard lock(m_mutex);
            if (const auto image = m_runtime_images.find(name); image != m_runtime_images.end()) {
                return image->second->header;
            }
            // Whatever the slot shows, a material reads the authored picture's header.
            if (const auto slot = m_cover_slots.find(name); slot != m_cover_slots.end()) {
                return slot->second.header;
            }
        }
        return m_fallback != nullptr ? m_fallback->ParseHeader(name) : ImageHeader {};
    }

    void SetTextureSurfaceSize(uint32_t width, uint32_t height) override {
        if (m_fallback != nullptr) m_fallback->SetTextureSurfaceSize(width, height);
    }

    bool IsRuntimeImage(const std::string& name) const {
        std::lock_guard lock(m_mutex);
        return m_runtime_images.contains(name) || m_cover_slots.contains(name);
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
        std::lock_guard lock(m_mutex);
        // A cover slot shows the cover, so it changes when the cover does.
        const auto slot = m_cover_slots.find(name);
        const auto version = m_versions.find(slot != m_cover_slots.end() ? slot->second.cover : name);
        return version == m_versions.end() ? 0 : version->second;
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
        if (rgba == nullptr) return false;
        std::lock_guard lock(m_mutex);
        const auto      found = m_runtime_images.find(name);
        if (found == m_runtime_images.end() || found->second == nullptr) return false;
        const Image& image = *found->second;
        if (image.header.format != TextureFormat::RGBA8 ||
            static_cast<uint32_t>(image.header.width) != width ||
            static_cast<uint32_t>(image.header.height) != height || image.slots.empty() ||
            image.slots.front().mipmaps.empty()) {
            return false;
        }
        const auto& level = image.slots.front().mipmaps.front();
        return level.data != nullptr && level.size >= 0 &&
               static_cast<std::size_t>(level.size) == rgba_len &&
               std::memcmp(level.data.get(), rgba, rgba_len) == 0;
    }

    void SetRgbaImage(std::string name, uint32_t width, uint32_t height, const uint8_t* rgba,
                      std::size_t rgba_len) {
        if (name.empty() || rgba == nullptr || width == 0 || height == 0 ||
            width > static_cast<uint32_t>(std::numeric_limits<int32_t>::max()) ||
            height > static_cast<uint32_t>(std::numeric_limits<int32_t>::max()) ||
            std::size_t(width) > std::numeric_limits<std::size_t>::max() / height / 4 ||
            rgba_len != std::size_t(width) * height * 4) {
            return;
        }
        std::lock_guard lock(m_mutex);
        const bool      is_cover_current = name == "$mediaThumbnail";
        const auto      earlier = m_runtime_images.find(name);
        const bool      had_earlier = earlier != m_runtime_images.end() && earlier->second != nullptr;
        const auto      earlier_image = had_earlier ? earlier->second : nullptr;
        const uint64_t  earlier_version = had_earlier ? m_versions[name] : 0;
        const auto      made = MakeImageLocked(name, width, height, rgba, rgba_len);
        PublishLocked(name, made.image, made.version);
        if (! is_cover_current) return;
        // The cover being replaced is what a wallpaper cross-fades from. A clear (or a first
        // image) has nothing to fade from, so both slots then hold the new picture.
        if (! IsEmptyCoverPixel(width, height, rgba[3]) && had_earlier) {
            PublishLocked("$mediaPreviousThumbnail", earlier_image, earlier_version);
        } else {
            PublishLocked("$mediaPreviousThumbnail", made.image, made.version);
        }
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
        std::lock_guard lock(m_mutex);
        const auto      source = m_runtime_images.find(from);
        if (source == m_runtime_images.end() || source->second == nullptr || to.empty()) return false;
        PublishLocked(to, source->second, m_versions[from]);
        return true;
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
        if (m_fallback == nullptr || authored_name.empty() || ! IsCoverName(cover_name)) {
            return cover_name;
        }
        const std::string slot_name = cover_name + "|" + authored_name;
        {
            std::lock_guard lock(m_mutex);
            if (m_cover_slots.contains(slot_name)) return slot_name;
        }
        // Read outside the lock: the fallback may touch the file system.
        const ImageHeader header = m_fallback->ParseHeader(authored_name);
        if (header.isVideo || header.isSprite || header.width <= 0 || header.height <= 0 ||
            ! IsColourPicture(header.format)) {
            return cover_name;
        }
        std::lock_guard lock(m_mutex);
        const bool      added = m_cover_slots
                              .try_emplace(slot_name, CoverSlot { .cover = cover_name,
                                                                  .authored_name = authored_name,
                                                                  .header = header })
                              .second;
        if (added) m_names_generation.fetch_add(1, std::memory_order_release);
        return slot_name;
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

    /// A fresh immutable RGBA8 image holding a private copy of the bytes, with the next version
    /// number of the one counter every name shares. Caller holds the lock.
    struct MadeImage {
        std::shared_ptr<Image> image;
        uint64_t               version { 0 };
    };
    MadeImage MakeImageLocked(const std::string& name, uint32_t width, uint32_t height,
                              const uint8_t* rgba, std::size_t rgba_len) {
        const uint64_t version = ++m_version_counter;
        auto image             = std::make_shared<Image>();
        image->key             = name + "#" + std::to_string(version);
        auto& header           = image->header;
        header.width = header.mapWidth = static_cast<i32>(width);
        header.height = header.mapHeight = static_cast<i32>(height);
        header.count                     = 1;
        header.format                    = TextureFormat::RGBA8;
        header.sample.wrapS              = TextureWrap::CLAMP_TO_EDGE;
        header.sample.wrapT              = TextureWrap::CLAMP_TO_EDGE;
        header.sample.minFilter          = TextureFilter::LINEAR;
        header.sample.magFilter          = TextureFilter::LINEAR;
        for (const char* component : { "compo1", "compo2", "compo3", "compo4" }) {
            header.extraHeader[component].val = 1;
        }
        auto& slot  = image->slots.emplace_back();
        slot.width  = header.width;
        slot.height = header.height;
        auto& level  = slot.mipmaps.emplace_back();
        level.width  = header.width;
        level.height = header.height;
        level.size   = static_cast<isize>(rgba_len);
        level.data   = ImageDataPtr(new uint8_t[rgba_len], [](uint8_t* data) { delete[] data; });
        std::memcpy(level.data.get(), rgba, rgba_len);
        return MadeImage { std::move(image), version };
    }

    /// Makes `name` hold `image` under `version`. A name that joins the set moves
    /// `NamesGeneration`; replacing one does not.
    void PublishLocked(const std::string& name, std::shared_ptr<Image> image, uint64_t version) {
        const bool joins = ! m_runtime_images.contains(name);
        m_runtime_images[name] = std::move(image);
        m_versions[name]       = version;
        if (joins) m_names_generation.fetch_add(1, std::memory_order_release);
    }

    mutable std::mutex                                      m_mutex;
    uint64_t                                                m_version_counter { 0 };
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

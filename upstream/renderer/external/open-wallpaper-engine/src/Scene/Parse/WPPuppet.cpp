#include "WPPuppet.hpp"

#include <algorithm>
#include <bit>
#include <cmath>

using namespace wallpaper;
using namespace wallpaper::linalg;

// The clean-room rewrite is specified in .plans/own-code/specs/parse/p5-models-puppets.md
// (stub ledger, section 12). Each marker below stands for one body to implement.

void WPPuppet::prepared() {
    // CLEANROOM LM7
}

void WPPuppet::evaluatePose(const WPPuppetLayer&, std::span<linalg::Affine3f>) const noexcept {
    // CLEANROOM LM8
}

WPPuppet::Animation::InterpolationInfo WPPuppet::Animation::getInterpolationInfo(double*) const {
    // CLEANROOM LM9
    return {};
}

void WPPuppetLayer::prepared(std::span<AnimationLayer>) {
    // CLEANROOM LM10
}

void WPPuppetLayer::rebuildBlend() noexcept {
    // CLEANROOM LM11
}

std::span<const linalg::Affine3f> WPPuppetLayer::genFrame(double time) noexcept {
    if (! m_puppet || ! m_state) return {};
    auto& state = *m_state;
    const auto time_bits = std::bit_cast<uint64_t>(time);
    if (state.m_pose_valid && std::isfinite(time) && state.m_pose_time_bits == time_bits) {
        return state.m_final_affines;
    }

    state.m_pose_valid = false;
    updateInterpolation(time);
    m_puppet->evaluatePose(*this, state.m_final_affines);
    state.m_pose_time_bits = time_bits;
    state.m_pose_valid =
        std::isfinite(time) && std::isfinite(state.m_last_elapsed) &&
        std::isfinite(state.m_global_blend) && std::isfinite(state.m_total_blend) &&
        std::all_of(state.m_layers.begin(), state.m_layers.end(), [](const Layer& layer) {
            const auto& authored = layer.anim_layer;
            return std::isfinite(authored.rate) && std::isfinite(authored.blend) &&
                   std::isfinite(authored.cur_time) && std::isfinite(layer.blend) &&
                   std::isfinite(layer.interp_info.t);
        });
    return state.m_final_affines;
}

void WPPuppetLayer::invalidatePose() noexcept {
    if (m_state) m_state->m_pose_valid = false;
}

void WPPuppetLayer::updateInterpolation(double) noexcept {
    // CLEANROOM LM12
}

std::vector<i32> WPPuppetLayer::takeFinishedLayers() noexcept {
    if (! m_state) return {};
    std::vector<i32> finished;
    finished.swap(m_state->m_finished_layers);
    return finished;
}

WPPuppetLayer::Layer* WPPuppetLayer::layerAt(i32 index) noexcept {
    if (! m_state || index < 0 || static_cast<usize>(index) >= m_state->m_layers.size()) {
        return nullptr;
    }
    return &m_state->m_layers[static_cast<usize>(index)];
}

const WPPuppetLayer::Layer* WPPuppetLayer::layerAt(i32 index) const noexcept {
    if (! m_state || index < 0 || static_cast<usize>(index) >= m_state->m_layers.size()) {
        return nullptr;
    }
    return &m_state->m_layers[static_cast<usize>(index)];
}

i32 WPPuppetLayer::findLayer(std::string_view name) const noexcept {
    if (! m_state) return -1;
    const auto& layers = m_state->m_layers;
    for (usize i = 0; i < layers.size(); i++) {
        if (layers[i].anim_layer.name == name) return static_cast<i32>(i);
    }
    // SceneScript also accepts the stack index.
    i32 index = 0;
    for (const char ch : name) {
        if (ch < '0' || ch > '9') return -1;
        index = index * 10 + (ch - '0');
        if (index > 4096) return -1;
    }
    if (name.empty() || static_cast<usize>(index) >= layers.size()) return -1;
    return index;
}

usize WPPuppetLayer::layerCount() const noexcept {
    return m_state ? m_state->m_layers.size() : 0;
}

std::string WPPuppetLayer::layerName(i32 index) const {
    const auto* layer = layerAt(index);
    return layer != nullptr ? layer->anim_layer.name : std::string {};
}

bool WPPuppetLayer::play(i32 index) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    invalidatePose();
    auto& alayer = layer->anim_layer;
    if (! alayer.playing && layer->anim != nullptr &&
        layer->anim->mode == WPPuppet::PlayMode::Single &&
        alayer.cur_time >= layer->anim->max_time) {
        alayer.cur_time = 0.0;
    }
    alayer.playing = true;
    return true;
}

bool WPPuppetLayer::pause(i32 index) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    invalidatePose();
    layer->anim_layer.playing = false;
    return true;
}

bool WPPuppetLayer::stop(i32 index) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    invalidatePose();
    layer->anim_layer.playing  = false;
    layer->anim_layer.cur_time = 0.0;
    if (layer->anim != nullptr) {
        layer->interp_info = layer->anim->getInterpolationInfo(&layer->anim_layer.cur_time);
    }
    return true;
}

bool WPPuppetLayer::isPlaying(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer != nullptr && layer->anim_layer.playing;
}

bool WPPuppetLayer::setFrame(i32 index, double frame) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr || layer->anim == nullptr || ! std::isfinite(frame)) return false;
    invalidatePose();
    const double frames = static_cast<double>(layer->anim->length);
    if (frame < 0.0) frame = 0.0;
    if (frame > frames) frame = frames;
    layer->anim_layer.cur_time = frame * layer->anim->frame_time;
    layer->interp_info = layer->anim->getInterpolationInfo(&layer->anim_layer.cur_time);
    return true;
}

double WPPuppetLayer::frame(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    if (layer == nullptr || layer->anim == nullptr || layer->anim->frame_time <= 0.0) return 0.0;
    return layer->anim_layer.cur_time / layer->anim->frame_time;
}

double WPPuppetLayer::frameCount(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    if (layer == nullptr || layer->anim == nullptr) return 0.0;
    return static_cast<double>(layer->anim->length);
}

double WPPuppetLayer::fps(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    if (layer == nullptr || layer->anim == nullptr) return 0.0;
    return layer->anim->fps;
}

bool WPPuppetLayer::setRate(i32 index, double rate) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr || ! std::isfinite(rate)) return false;
    invalidatePose();
    layer->anim_layer.rate = rate;
    return true;
}

double WPPuppetLayer::rate(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer == nullptr ? 0.0 : layer->anim_layer.rate;
}

bool WPPuppetLayer::setBlend(i32 index, double blend) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr || ! std::isfinite(blend)) return false;
    if (layer->anim_layer.blend == blend) return true;
    invalidatePose();
    layer->anim_layer.blend = blend;
    rebuildBlend();
    return true;
}

double WPPuppetLayer::blend(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer == nullptr ? 0.0 : layer->anim_layer.blend;
}

bool WPPuppetLayer::setVisible(i32 index, bool visible) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    if (layer->anim_layer.visible == visible) return true;
    invalidatePose();
    layer->anim_layer.visible = visible;
    rebuildBlend();
    return true;
}

bool WPPuppetLayer::visible(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer != nullptr && layer->anim_layer.visible;
}

WPPuppetLayer::WPPuppetLayer(std::shared_ptr<WPPuppet> pup)
    : m_state(pup ? std::make_shared<State>() : nullptr), m_puppet(std::move(pup)) {
    if (m_state) m_state->m_final_affines.resize(m_puppet->bones.size());
}
WPPuppetLayer::WPPuppetLayer()  = default;
WPPuppetLayer::~WPPuppetLayer() = default;

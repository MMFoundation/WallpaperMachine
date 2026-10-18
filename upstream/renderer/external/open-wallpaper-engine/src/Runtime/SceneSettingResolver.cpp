#include "Runtime/SceneSettingResolver.hpp"

#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/ScriptedDynamicValue.hpp"
#include "Scripting/ScriptModuleSyntax.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <sstream>

// CLEANROOM: the stubs below leave their parameters unused until they are rewritten.
#pragma clang diagnostic ignored "-Wunused-parameter"

namespace wallpaper
{
namespace
{

linalg::Vector3f parse_vec3(const nlohmann::json& value) {
    // CLEANROOM RT6
    return linalg::Vector3f::Zero();
}

// Vector settings carry one initial value per component, either as an array or
// as a space-separated string. Scalars keep the plain single-value reading.
bool parse_bool(const nlohmann::json& value) {
    // CLEANROOM RT6
    return false;
}

std::optional<ConditionInfo> parse_condition(const nlohmann::json& setting, std::string* user_name) {
    // CLEANROOM RT7
    return std::nullopt;
}

DynamicValueUniquePtr resolve_auto_setting(SceneRuntimeContext& context, const nlohmann::json& setting);
DynamicValueUniquePtr resolve_auto_setting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name);

DynamicValueUniquePtr resolve_auto_setting(SceneRuntimeContext& context, const nlohmann::json& setting) {
    // CLEANROOM RT8
    return std::make_unique<DynamicValue>();
}

DynamicValueUniquePtr resolve_auto_setting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name) {
    // CLEANROOM RT8
    return std::make_unique<DynamicValue>();
}

} // namespace

bool InitialBoolSetting(const nlohmann::json& setting)
{
    return parse_bool(setting);
}

std::string UserPropertyName(const nlohmann::json& setting)
{
    std::string user_name;
    parse_condition(setting, &user_name);
    return user_name;
}

float ScalarAnimation::Evaluate(double seconds) const {
    // CLEANROOM RT5
    return 0.0f;
}

double ScalarAnimation::FrameCount() const
{
    return length_frames > 0.0 ? length_frames : (keyframes.empty() ? 0.0 : keyframes.back().frame);
}

namespace
{
// Markers fire as the playhead travels across their frame: departure exclusive,
// arrival inclusive, in the order they are met. A loop runs on a circle, so the
// distance is measured along the direction of travel — that makes a wrap, an
// exact landing on the seam and a marker authored at the period the same point.
// Travelling at least a whole period reports each marker once, never once per
// lap, so one stalled frame cannot flood the queue.
void CollectCrossedEvents(const ScalarAnimation& animation, double previous, double travelled,
                          double length, std::vector<ScalarAnimationEvent>& out)
{
    if (animation.events.empty() || travelled == 0.0 || !std::isfinite(travelled)) return;

    if (animation.mode != ScalarAnimationMode::Loop || !(length > 0.0)) {
        const double arrival = std::clamp(previous + travelled, 0.0, std::max(0.0, length));
        if (travelled > 0.0) {
            for (const auto& event : animation.events) {
                if (!event.name.empty() && event.frame > previous && event.frame <= arrival) {
                    out.push_back(event);
                }
            }
        } else {
            for (auto event = animation.events.rbegin(); event != animation.events.rend(); ++event) {
                if (!event->name.empty() && event->frame >= arrival && event->frame < previous) {
                    out.push_back(*event);
                }
            }
        }
        return;
    }

    const auto wrap = [length](double value) {
        const double wrapped = std::fmod(value, length);
        return wrapped < 0.0 ? wrapped + length : wrapped;
    };
    const double start    = wrap(previous);
    const double distance = std::abs(travelled);
    const bool   forward  = travelled > 0.0;
    std::vector<std::pair<double, const ScalarAnimationEvent*>> met;
    for (const auto& event : animation.events) {
        if (event.name.empty()) continue;
        const double delta = wrap(forward ? event.frame - start : start - event.frame);
        if (distance >= length) {
            // A full lap returns to the departure frame, so that marker is last.
            met.emplace_back(delta == 0.0 ? length : delta, &event);
        } else if (delta > 0.0 && delta <= distance) {
            met.emplace_back(delta, &event);
        }
    }
    std::sort(met.begin(), met.end(), [](const auto& left, const auto& right) {
        return left.first < right.first;
    });
    for (const auto& [delta, event] : met) out.push_back(*event);
}
} // namespace

void ScalarAnimationPlayback::Advance(double seconds)
{
    if (!playing || !std::isfinite(seconds) || seconds <= 0.0) return;
    const double length = animation.FrameCount();
    const double previous = frame;
    const double next = frame + seconds * animation.fps * rate;
    if (animation.mode == ScalarAnimationMode::Loop && length > 0.0) {
        frame = std::fmod(next, length);
        if (frame < 0.0) frame += length;
    } else {
        frame = std::clamp(next, 0.0, std::max(0.0, length));
        if ((rate > 0.0 && next >= length) || (rate < 0.0 && next <= 0.0)) playing = false;
    }
    CollectCrossedEvents(animation, previous, next - previous, length, pending_events);
}

void ScalarAnimationPlayback::Play()
{
    if (!playing && animation.mode == ScalarAnimationMode::Single) {
        if (rate >= 0.0 && frame >= animation.FrameCount()) frame = 0.0;
        else if (rate < 0.0 && frame <= 0.0) frame = animation.FrameCount();
    }
    playing = true;
}

void ScalarAnimationPlayback::Stop()
{
    playing = false;
    frame = 0.0;
}

void ScalarAnimationPlayback::SetFrame(double value)
{
    if (std::isfinite(value)) frame = std::clamp(value, 0.0, std::max(0.0, animation.FrameCount()));
}

float ScalarAnimationPlayback::Value() const
{
    return animation.Evaluate(animation.fps > 0.0 ? frame / animation.fps : 0.0);
}

std::unique_ptr<DynamicValue> ResolveBoolSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name,
    int animation_layer_index) {
    // CLEANROOM RT9
    return std::make_unique<DynamicValue>();
}

std::unique_ptr<DynamicValue> ResolveFloatSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name,
    int animation_layer_index) {
    // CLEANROOM RT9
    return std::make_unique<DynamicValue>();
}

std::unique_ptr<DynamicValue> ResolveVec3Setting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name,
    Vec3SettingSemantic semantic) {
    // CLEANROOM RT9
    return std::make_unique<DynamicValue>();
}

std::unique_ptr<DynamicValue> ResolveVectorSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::size_t components,
    std::string_view current_layer_name) {
    // CLEANROOM RT9
    return std::make_unique<DynamicValue>();
}

std::unique_ptr<DynamicValue> ResolveStringSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& setting,
    std::string_view current_layer_name) {
    // CLEANROOM RT9
    return std::make_unique<DynamicValue>();
}

namespace
{
// The three curves of a vec3 setting, before any clock is chosen for them.
struct Vec3Timeline
{
    std::array<ScalarAnimation, 3> components;
    std::array<float, 3>           offset {};
    // The first keyed component supplies the clock's play state.
    std::size_t first { 3 };
    double      last_frame { 0.0 };
    // The setting this one is keyed together with (`options.parent.key`).
    std::string parent;
};

std::optional<Vec3Timeline> ReadVec3Timeline(const nlohmann::json& setting)
{
    if (!setting.is_object()) return std::nullopt;
    const auto source = setting.find("animation");
    if (source == setting.end() || !source->is_object()) return std::nullopt;

    Vec3Timeline timeline;
    const auto base = parse_vec3(setting);
    const auto relative_value = source->find("relative");
    const bool relative = relative_value != source->end() && relative_value->is_boolean() &&
                          relative_value->get<bool>();
    for (std::size_t i = 0; i < timeline.components.size(); ++i) {
        timeline.offset[i] = relative ? base[i] : 0.0f;
        auto curve = ResolveScalarAnimation(setting, i);
        if (!curve) {
            timeline.components[i].initial_value = relative ? 0.0f : base[i];
            continue;
        }
        if (timeline.first == timeline.components.size()) timeline.first = i;
        if (relative) curve->initial_value = 0.0f;
        timeline.last_frame = std::max(timeline.last_frame, curve->keyframes.back().frame);
        timeline.components[i] = std::move(*curve);
    }
    if (timeline.first == timeline.components.size()) return std::nullopt;

    if (const auto options = source->find("options"); options != source->end() &&
                                                      options->is_object()) {
        if (const auto parent = options->find("parent"); parent != options->end() &&
                                                         parent->is_object()) {
            const auto key = parent->find("key");
            if (key != parent->end() && key->is_string()) timeline.parent = key->get<std::string>();
        }
    }
    return timeline;
}

// The clock a timeline plays on: its first keyed curve's play state, as long as
// the longest curve of everything driven by it unless the author gave a length.
ScalarAnimation Vec3TimelineClock(const Vec3Timeline& timeline, double last_frame)
{
    auto clock = timeline.components[timeline.first];
    if (!(clock.length_frames > 0.0)) clock.length_frames = last_frame;
    return clock;
}

std::shared_ptr<NodeVec3Animation> MakeVec3Animation(
    Vec3Timeline timeline, std::shared_ptr<ScalarAnimationPlayback> playback)
{
    auto animation = std::make_shared<NodeVec3Animation>();
    animation->playback   = std::move(playback);
    animation->components = std::move(timeline.components);
    animation->offset     = timeline.offset;
    // Only the clock wraps; short component curves must hold their last key
    // until that shared clock loops, just like vector material timelines.
    for (auto& curve : animation->components) curve.mode = ScalarAnimationMode::Single;
    return animation;
}
} // namespace

std::array<float, 3> NodeVec3Animation::Value() const
{
    const double frame = playback != nullptr ? playback->frame : 0.0;
    std::array<float, 3> value;
    for (std::size_t i = 0; i < components.size(); ++i) {
        const auto& curve = components[i];
        value[i] = offset[i] + curve.Evaluate(curve.fps > 0.0 ? frame / curve.fps : 0.0);
    }
    return value;
}

void RegisterNodeTransformSettings(SceneRuntimeContext& context, SceneNode* node,
                                   std::string_view layer_name, const nlohmann::json& origin,
                                   const nlohmann::json& scale, const nlohmann::json& angles,
                                   bool animate)
{
    if (node == nullptr) return;
    static constexpr std::array<const char*, 3> keys { "origin", "scale", "angles" };
    const std::array<const nlohmann::json*, 3> settings { &origin, &scale, &angles };
    const std::string name(layer_name);

    // Do not introduce a second writer for a script or user property.
    std::array<std::optional<Vec3Timeline>, 3> timelines;
    std::array<bool, 3>                        bound {};
    for (std::size_t i = 0; i < settings.size(); ++i) {
        const auto& setting = *settings[i];
        if (!setting.is_object()) continue;
        bound[i] = setting.contains("script") || setting.contains("user");
        if (!bound[i] && animate) timelines[i] = ReadVec3Timeline(setting);
    }

    // A setting keyed under another one plays on that one's clock, however long
    // the chain; a parent that has no timeline, or a cycle, leaves it its own.
    const auto root_of = [&](std::size_t property) {
        std::size_t root = property;
        for (std::size_t step = 0; step < keys.size(); ++step) {
            const auto parent = std::find_if(keys.begin(), keys.end(), [&](const char* key) {
                return timelines[root]->parent == key;
            });
            if (parent == keys.end()) return root;
            const auto index = static_cast<std::size_t>(parent - keys.begin());
            if (!timelines[index]) return root;
            root = index;
        }
        return property;
    };
    std::array<std::size_t, 3> roots {};
    std::array<double, 3>      group_last_frame {};
    for (std::size_t i = 0; i < timelines.size(); ++i) {
        if (!timelines[i]) continue;
        roots[i] = root_of(i);
        group_last_frame[roots[i]] = std::max(group_last_frame[roots[i]], timelines[i]->last_frame);
    }
    std::array<std::shared_ptr<ScalarAnimationPlayback>, 3> clocks;
    for (std::size_t i = 0; i < timelines.size(); ++i) {
        if (!timelines[i] || roots[i] != i) continue;
        clocks[i] = context.RegisterScalarAnimation(
            layer_name, Vec3TimelineClock(*timelines[i], group_last_frame[i]));
    }

    const auto animation_of = [&](std::size_t property) {
        return timelines[property]
                   ? std::shared_ptr<const NodeVec3Animation>(
                         MakeVec3Animation(std::move(*timelines[property]), clocks[roots[property]]))
                   : nullptr;
    };
    if (bound[0] || timelines[0]) {
        context.RegisterNodeTranslate(name, node, ResolveVec3Setting(context, origin, layer_name),
                                      animation_of(0));
    }
    if (bound[1] || timelines[1]) {
        context.RegisterNodeScale(name, node,
                                  ResolveVec3Setting(context, scale, layer_name,
                                                     Vec3SettingSemantic::Generic),
                                  animation_of(1));
    }
    if (bound[2] || timelines[2]) {
        context.RegisterNodeRotation(name, node,
                                     ResolveVec3Setting(context, angles, layer_name,
                                                        Vec3SettingSemantic::AnglesDegrees),
                                     animation_of(2));
    }
}

std::shared_ptr<const NodeVec3Animation>
ResolveVec3Animation(SceneRuntimeContext& context, std::string_view layer_name,
                     const nlohmann::json& setting)
{
    auto timeline = ReadVec3Timeline(setting);
    if (!timeline) return nullptr;
    auto clock = Vec3TimelineClock(*timeline, timeline->last_frame);
    return MakeVec3Animation(std::move(*timeline),
                             context.RegisterScalarAnimation(layer_name, std::move(clock)));
}

namespace
{
// `wraploop`: the curve is cut at the timeline's length and ends on a key at
// that frame holding the first key's value, so a loop returns to where it began
// instead of holding its last key until the length and then jumping back
// (Wallpaper Engine's FUN_1401a98b0, run on every curve of a timeline that sets
// the flag). Keys past the length go, but never down to fewer than two. The
// closing key's incoming handle mirrors the first key's outgoing one, so the
// seam is as smooth as the curve is at its start. A curve with fewer than two
// keys, or a timeline with no length, is left as authored.
void CloseCurveAtLoopLength(ScalarAnimation& curve)
{
    auto& keys = curve.keyframes;
    if (!(curve.length_frames > 0.0) || keys.size() < 2) return;
    while (keys.size() > 1 && curve.length_frames < keys.back().frame) keys.pop_back();
    if (keys.size() < 2) return;

    const ScalarAnimationKeyframe first = keys.front();
    if (keys.back().frame != curve.length_frames) {
        ScalarAnimationKeyframe closing;
        closing.frame = curve.length_frames;
        keys.push_back(closing);
    }
    auto& closing = keys.back();
    closing.value = first.value;
    closing.back  = ScalarAnimationHandle { -first.front.x, -first.front.y, first.front.enabled };
}
} // namespace

std::optional<ScalarAnimation> ResolveScalarAnimation(const nlohmann::json& setting,
                                                      std::size_t component) {
    // CLEANROOM RT10
    return std::nullopt;
}

} // namespace wallpaper

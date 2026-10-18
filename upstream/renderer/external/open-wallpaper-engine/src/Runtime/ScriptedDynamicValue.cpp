#include "Runtime/ScriptedDynamicValue.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scripting/ScriptEngine.hpp"

// CLEANROOM: the stubs below leave their parameters unused until they are rewritten.
#pragma clang diagnostic ignored "-Wunused-parameter"

namespace wallpaper
{

ScriptedDynamicValue::ScriptedDynamicValue(
    SceneRuntimeContext& runtime, std::string script_source, std::string current_layer_name,
    std::map<std::string, DynamicValueUniquePtr> script_properties, DynamicValue base_value,
    ScriptedValueSemantic semantic, int animation_layer_index) {
    // CLEANROOM RT11
}

ScriptedDynamicValue::~ScriptedDynamicValue() {
    // The runtime lists every scripted value it should tick and tear down; one
    // that is destroyed first takes itself off the list.
    if (! m_registry.expired()) m_runtime->UnregisterScriptedValue(this);
}

void ScriptedDynamicValue::reevaluate() {
    if (m_runtime->ProjectPropertiesChanging() || m_program == nullptr || ! m_program->Valid()) return;

    // update(value) continues from the previous result, including explicit property writes.
    SceneRuntimeContext::OwnTextWrite own_text_write(*m_runtime, *this);
    auto result = m_program->Evaluate(m_runtime->hostContext(), *this);
    if (! m_program->Capabilities().update || result == nullptr) return;
    // The text script that writes its own layer's text and returns nothing has
    // decided the text: the current value would put the string it started with
    // back over the write.
    if (own_text_write.Written().has_value() && ! m_program->UpdateReturnedValue()) {
        DynamicValue::update(*own_text_write.Written());
    } else {
        DynamicValue::update(*result);
    }
}

void ScriptedDynamicValue::ApplyProjectProperties(const ProjectProperties& project_properties,
                                                 const ProjectProperties& changed_properties) {
    if (m_program != nullptr) m_program->ApplyProjectProperties(project_properties, changed_properties);
}

uint8_t ScriptedDynamicValue::CursorHandlerMask() const noexcept {
    return m_program != nullptr && m_program->Valid() ? m_program->Capabilities().cursor_handlers : 0;
}

void ScriptedDynamicValue::DispatchCursorClick(const ScriptHostContext& host_context) {
    // CLEANROOM RT11
}

void ScriptedDynamicValue::DispatchCursorDown(const ScriptHostContext& host_context) {
    // CLEANROOM RT11
}

void ScriptedDynamicValue::DispatchCursorEnter(const ScriptHostContext& host_context) {
    // CLEANROOM RT11
}

void ScriptedDynamicValue::DispatchCursorLeave(const ScriptHostContext& host_context) {
    // CLEANROOM RT11
}

void ScriptedDynamicValue::DispatchCursorMove(const ScriptHostContext& host_context) {
    // CLEANROOM RT11
}

void ScriptedDynamicValue::DispatchCursorUp(const ScriptHostContext& host_context) {
    // CLEANROOM RT11
}

void ScriptedDynamicValue::DispatchAnimationEvent(const ScriptHostContext& host_context,
                                                  std::string_view event_name, double frame) {
    if (m_program != nullptr) m_program->DispatchAnimationEvent(host_context, event_name, frame);
}

void ScriptedDynamicValue::DispatchMediaThumbnailChanged(const linalg::Vector3f& primary_color,
                                                         const linalg::Vector3f& text_color) {
    // CLEANROOM RT11
}

void ScriptedDynamicValue::DispatchMediaEventJson(std::string_view event_json) {
    // CLEANROOM RT11
}

void ScriptedDynamicValue::DispatchResizeScreen(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchResizeScreen(host_context);
}

void ScriptedDynamicValue::DispatchGeneralSettings(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchGeneralSettings(host_context);
}

void ScriptedDynamicValue::Destroy() {
    if (m_program != nullptr) m_program->Destroy();
}

} // namespace wallpaper

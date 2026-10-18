#include "Runtime/DynamicValue.hpp"

#include "Project/ProjectProperties.hpp"
#include "Utils/Logging.h"

#include <sstream>

// CLEANROOM: the stubs below leave their parameters unused until they are rewritten.
#pragma clang diagnostic ignored "-Wunused-parameter"

namespace wallpaper
{
DynamicValue::DynamicValue(const linalg::Vector4i& value) { update(value); }
DynamicValue::DynamicValue(const linalg::Vector3i& value) { update(value); }
DynamicValue::DynamicValue(const linalg::Vector2i& value) { update(value); }
DynamicValue::DynamicValue(const linalg::Vector4f& value) { update(value); }
DynamicValue::DynamicValue(const linalg::Vector3f& value) { update(value); }
DynamicValue::DynamicValue(const linalg::Vector2f& value) { update(value); }
DynamicValue::DynamicValue(float value) {
    // CLEANROOM RT1
}
DynamicValue::DynamicValue(int value) {
    // CLEANROOM RT1
}
DynamicValue::DynamicValue(bool value) {
    // CLEANROOM RT1
}
DynamicValue::DynamicValue(std::string value) {
    // CLEANROOM RT1
}

DynamicValue::~DynamicValue() {
    // CLEANROOM RT1
}

const linalg::Vector4i& DynamicValue::getIVec4() const { return m_ivec4; }
const linalg::Vector3i& DynamicValue::getIVec3() const { return m_ivec3; }
const linalg::Vector2i& DynamicValue::getIVec2() const { return m_ivec2; }
const linalg::Vector4f& DynamicValue::getVec4() const { return m_vec4; }
const linalg::Vector3f& DynamicValue::getVec3() const { return m_vec3; }
const linalg::Vector2f& DynamicValue::getVec2() const { return m_vec2; }
const float& DynamicValue::getFloat() const {
    // CLEANROOM RT2
    static const float neutral {};
    return neutral;
}
const int& DynamicValue::getInt() const {
    // CLEANROOM RT2
    static const int neutral {};
    return neutral;
}
const bool& DynamicValue::getBool() const {
    // CLEANROOM RT2
    static const bool neutral {};
    return neutral;
}
const std::string& DynamicValue::getString() const {
    // CLEANROOM RT2
    static const std::string neutral {};
    return neutral;
}
DynamicValue::UnderlyingType DynamicValue::getType() const {
    // CLEANROOM RT2
    return {};
}

std::string DynamicValue::toString() const {
    // CLEANROOM RT2
    return {};
}

void DynamicValue::update(float new_value) {
    // CLEANROOM RT3
}

void DynamicValue::update(int new_value) {
    // CLEANROOM RT3
}

void DynamicValue::update(bool new_value) {
    // CLEANROOM RT3
}

void DynamicValue::update(const linalg::Vector2f& new_value) {
    // CLEANROOM RT3
}

void DynamicValue::update(const linalg::Vector3f& new_value) {
    // CLEANROOM RT3
}

void DynamicValue::update(const linalg::Vector4f& new_value) {
    // CLEANROOM RT3
}

void DynamicValue::update(const linalg::Vector2i& new_value) {
    // CLEANROOM RT3
}

void DynamicValue::update(const linalg::Vector3i& new_value) {
    // CLEANROOM RT3
}

void DynamicValue::update(const linalg::Vector4i& new_value) {
    // CLEANROOM RT3
}

void DynamicValue::update(const std::string& new_value) {
    // CLEANROOM RT3
}

void DynamicValue::update(const DynamicValue& other) {
    // CLEANROOM RT3
}

void DynamicValue::update() {
    // CLEANROOM RT3
}

std::function<void()> DynamicValue::listen(const std::function<void(const DynamicValue&)>& callback) {
    // CLEANROOM RT4
    return {};
}

void DynamicValue::connect(DynamicValue* other) {
    // CLEANROOM RT4
}

void DynamicValue::connectVec3(DynamicValue* other) {
    // CLEANROOM RT4
}

void DynamicValue::disconnect() {
    // CLEANROOM RT4
}

void DynamicValue::attachCondition(const ConditionInfo& condition) {
    // CLEANROOM RT4
}

void DynamicValue::propagate() const {
    // CLEANROOM RT4
}

} // namespace wallpaper

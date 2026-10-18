#include "Looper.hpp"

using namespace wallpaper::looper;

void Looper::setName(std::string_view name) {
    // CLEANROOM UV41
    (void)name;
}

void Looper::setLogScope(uint64_t scope) { m_log_scope = scope; }

const std::string_view Looper::name() const {
    // CLEANROOM UV42
    return {};
}

Looper::Looper() {
    // CLEANROOM UV39
}
Looper::~Looper() {
    // CLEANROOM UV40
}

status_t Looper::start() {
    // CLEANROOM UV43
    return status_t::INVALID_OPERATION;
}

void Looper::stop() {
    // CLEANROOM UV44
}

void Looper::post(const std::shared_ptr<Message>& msg) {
    // CLEANROOM UV45
    (void)msg;
}

handler_id Looper::registerHandler(const std::shared_ptr<Handler>& handler) {
    // CLEANROOM UV46
    (void)handler;
    return Handler::INVALID_HANDLER_ID;
}

void Looper::unregisterHandler(handler_id id) {
    // CLEANROOM UV47
    (void)id;
}

Handler::Handler(): m_id(INVALID_HANDLER_ID) {
    // CLEANROOM UV48
}

int32_t Handler::id() const {
    // CLEANROOM UV49
    return INVALID_HANDLER_ID;
}
std::weak_ptr<Looper> Handler::getLooper() const {
    // CLEANROOM UV50
    return {};
}

bool Handler::setID(handler_id id, std::weak_ptr<Looper> looper) {
    // CLEANROOM UV51
    (void)id;
    (void)looper;
    return false;
}

void Handler::clearID(handler_id id) {
    handler_id expected = id;
    if (m_id.compare_exchange_strong(expected, INVALID_HANDLER_ID)) m_looper.reset();
}

Message::Message() {
    // CLEANROOM UV52
}
Message::Message(uint32_t what, const std::shared_ptr<Handler>& handler) {
    // CLEANROOM UV53
    (void)what;
    (void)handler;
}

uint32_t Message::what() const {
    // CLEANROOM UV54
    return 0;
}

std::shared_ptr<Message> Message::create() {
    // CLEANROOM UV55
    return nullptr;
}
std::shared_ptr<Message> Message::create(uint32_t what, const std::shared_ptr<Handler>& handler) {
    // CLEANROOM UV56
    (void)what;
    (void)handler;
    return nullptr;
}

void Message::setTarget(const std::shared_ptr<Handler>& handler) {
    // CLEANROOM UV57
    (void)handler;
}

void Message::setWhat(uint32_t what) {
    // CLEANROOM UV58
    (void)what;
}

status_t Message::post() {
    // CLEANROOM UV59
    return status_t::INVALID_OPERATION;
}

bool Message::setBool(std::string_view name, bool value) {
    // CLEANROOM UV60
    (void)name;
    (void)value;
    return false;
}

bool Message::setInt32(std::string_view name, int32_t value) {
    // CLEANROOM UV61
    (void)name;
    (void)value;
    return false;
}

bool Message::setFloat(std::string_view name, float value) {
    // CLEANROOM UV62
    (void)name;
    (void)value;
    return false;
}

bool Message::setString(std::string_view name, std::string value) {
    // CLEANROOM UV63
    (void)name;
    (void)value;
    return false;
}

bool Message::findBool(std::string_view name, bool* value) const {
    // CLEANROOM UV64
    (void)name;
    (void)value;
    return false;
}

bool Message::findInt32(std::string_view name, int32_t* value) const {
    // CLEANROOM UV65
    (void)name;
    (void)value;
    return false;
}

bool Message::findFloat(std::string_view name, float* value) const {
    // CLEANROOM UV66
    (void)name;
    (void)value;
    return false;
}

bool Message::findString(std::string_view name, std::string* value) const {
    // CLEANROOM UV67
    (void)name;
    (void)value;
    return false;
}

bool Message::setObject(std::string_view name, const std::shared_ptr<void>& value) {
    // CLEANROOM UV68
    (void)name;
    (void)value;
    return false;
}

#include "ThreadTimer.hpp"

#include "Utils/Logging.h"

#include <algorithm>
#include <cassert>

// CLEANROOM: the stubs below leave their parameters unused until they are rewritten.
#pragma clang diagnostic ignored "-Wunused-parameter"

using namespace wallpaper;
using micros = std::chrono::microseconds;

ThreadTimer::ThreadTimer(std::function<void()> cb) {
    // CLEANROOM RT32
    (void)cb;
}
ThreadTimer::~ThreadTimer() {
    // CLEANROOM RT32
}

bool ThreadTimer::Running() const {
    // CLEANROOM RT32
    return false;
}

void ThreadTimer::SetInterval(micros v) {
    // CLEANROOM RT32
}

void ThreadTimer::SetMinInterval(micros v) {
    // CLEANROOM RT32
}

void ThreadTimer::SetIdle(bool idle) {
    // CLEANROOM RT32
}

bool ThreadTimer::Idle() const {
    // CLEANROOM RT32
    return false;
}

void ThreadTimer::WakeOnce() {
    // CLEANROOM RT32
}

void ThreadTimer::WakeAt(std::chrono::steady_clock::time_point when) {
    // CLEANROOM RT32
}

void ThreadTimer::FireNow() {
    // CLEANROOM RT32
}

void ThreadTimer::Start() {
    // CLEANROOM RT32
}

void ThreadTimer::Stop() {
    // CLEANROOM RT32
}

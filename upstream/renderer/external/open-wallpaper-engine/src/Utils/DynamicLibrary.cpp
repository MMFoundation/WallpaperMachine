// This project's own code, written from the clean-room specification
// (specs/engine/e7-small-units.md).
#include "Utils/DynamicLibrary.hpp"

#include <dlfcn.h>

#include "Utils/Logging.h"

namespace utils
{

DynamicLibrary::DynamicLibrary() = default;

DynamicLibrary::DynamicLibrary(const char* filename) { Open(filename); }

DynamicLibrary::~DynamicLibrary() { Close(); }

DynamicLibrary::DynamicLibrary(DynamicLibrary&& o) noexcept: handle(o.handle) {
    o.handle = nullptr;
}

DynamicLibrary& DynamicLibrary::operator=(DynamicLibrary&& o) noexcept {
    if (this != &o) {
        Close();
        handle   = o.handle;
        o.handle = nullptr;
    }
    return *this;
}

// Opens the library, closing any one held before; false when it can't be loaded.
bool DynamicLibrary::Open(const char* filename) {
    Close();
    if (filename == nullptr) return false;
    handle = dlopen(filename, RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        const char* reason = dlerror();
        LOG_ERROR("can't load library %s: %s", filename, reason != nullptr ? reason : "unknown");
    }
    return handle != nullptr;
}

bool DynamicLibrary::IsOpen() const { return handle != nullptr; }

void DynamicLibrary::Close() {
    if (handle == nullptr) return;
    dlclose(handle);
    handle = nullptr;
}

void* DynamicLibrary::GetSymbolAddr(const char* name) const {
    if (handle == nullptr || name == nullptr) return nullptr;
    return dlsym(handle, name);
}

} // namespace utils

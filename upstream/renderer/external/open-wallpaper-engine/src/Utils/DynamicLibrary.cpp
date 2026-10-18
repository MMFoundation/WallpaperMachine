#include "Utils/DynamicLibrary.hpp"

namespace utils
{

DynamicLibrary::DynamicLibrary() = default;

DynamicLibrary::DynamicLibrary(const char* filename) { Open(filename); }

DynamicLibrary::~DynamicLibrary() { Close(); }

DynamicLibrary::DynamicLibrary(DynamicLibrary&&) noexcept {
    // CLEANROOM U14: implement from specs/engine/e7-small-units.md
}

DynamicLibrary& DynamicLibrary::operator=(DynamicLibrary&&) noexcept {
    // CLEANROOM U15: implement from specs/engine/e7-small-units.md
    return *this;
}

bool DynamicLibrary::Open(const char*) {
    // CLEANROOM U16: implement from specs/engine/e7-small-units.md
    return false;
}

bool DynamicLibrary::IsOpen() const { return handle != nullptr; }

void DynamicLibrary::Close() {
    // CLEANROOM U17: implement from specs/engine/e7-small-units.md
}

void* DynamicLibrary::GetSymbolAddr(const char*) const {
    // CLEANROOM U18: implement from specs/engine/e7-small-units.md
    return nullptr;
}

} // namespace utils

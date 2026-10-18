#pragma once

#include <utility>
#include "Core/NoCopyMove.hpp"

namespace utils
{

class DynamicLibrary : NoCopy {
public:
    DynamicLibrary();
    ~DynamicLibrary();

    DynamicLibrary(const char* filename);

    DynamicLibrary(DynamicLibrary&& o) noexcept;
    DynamicLibrary& operator=(DynamicLibrary&& o) noexcept;

    bool IsOpen() const;
    bool Open(const char* filename);
    void Close();

    void* GetSymbolAddr(const char* name) const;
    
    template<typename T>
    bool GetSymbol(const char*, T&) const {
        // CLEANROOM U19: implement from specs/engine/e7-small-units.md
        return false;
    }

private:
    void* handle { nullptr };
};
} // namespace wallpaper

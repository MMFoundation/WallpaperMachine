#pragma once

#include <type_traits>
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
    
    // Looks `name` up and stores it in `out`, a pointer or function-pointer variable.
    template<typename T>
    bool GetSymbol(const char* name, T& out) const {
        static_assert(std::is_pointer_v<T>, "a symbol is stored in a pointer");
        void* address = GetSymbolAddr(name);
        if (address == nullptr) return false;
        out = reinterpret_cast<T>(address);
        return true;
    }

private:
    void* handle { nullptr };
};
} // namespace wallpaper

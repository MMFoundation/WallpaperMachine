#pragma once

#define AUTO_DELETER(name, del_func) wallpaper::AutoDeleter del_##name(del_func);

namespace wallpaper
{
template<typename TDeleter>
struct AutoDeleter {
    AutoDeleter(TDeleter&& del): m_del(std::move(del)) {}
    ~AutoDeleter() {
        // CLEANROOM U21: implement from specs/engine/e7-small-units.md
    }
    TDeleter m_del;
};
} // namespace wallpaper

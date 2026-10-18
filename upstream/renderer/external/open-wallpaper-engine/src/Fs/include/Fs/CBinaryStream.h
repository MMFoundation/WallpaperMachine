#pragma once

#include <cstdio>
#include <string>
#include <string_view>
#include <limits>
#include <cassert>
#include <memory>
#include <filesystem>
#include "IBinaryStream.h"
#include "Utils/Logging.h"

namespace wallpaper
{
namespace fs
{
template<typename TBinaryStream>
class CBinaryStream : public TBinaryStream {
public:
    virtual ~CBinaryStream() {
        // CLEANROOM UV1
    }

protected:
    CBinaryStream(std::string_view path, std::FILE* file): m_path(path), m_file(file) {}
    virtual usize Write_impl(const void* buffer, usize sizeInBytes) override {
        // CLEANROOM UV2
        (void)buffer;
        (void)sizeInBytes;
        return 0;
    }

public:
    virtual usize Read(void* buffer, usize sizeInBytes) override {
        return std::fread(buffer, 1, sizeInBytes, m_file);
    }
    virtual char* Gets(char* buffer, usize sizeStr) override {
        // CLEANROOM UV3
        (void)buffer;
        (void)sizeStr;
        return nullptr;
    }
    virtual idx   Tell() const override {
        // CLEANROOM UV4
        return 0;
    }
    // Like the other streams, only a position in [0, size] is reachable.
    virtual bool  SeekSet(idx offset) override { return SeekTo(offset); }
    virtual bool  SeekCur(idx offset) override {
        const idx cur = std::ftell(m_file);
        return cur >= 0 && SeekTo(cur + offset);
    }
    virtual bool  SeekEnd(idx offset) override { return SeekTo(Size() + offset); }
    virtual isize Size() const override {
        // CLEANROOM UV5
        return 0;
    }

private:
    bool SeekTo(idx target) {
        if (target < 0 || target > Size()) return false;
        return std::fseek(m_file, target, SEEK_SET) == 0;
    }

    std::string m_path;
    std::FILE*  m_file;
};

template<typename TBinaryStream>
inline std::shared_ptr<TBinaryStream> t_CreateCBinaryStream(std::string_view path,
                                                            const char*      mode) {
    // CLEANROOM UV6
    (void)path;
    (void)mode;
    return nullptr;
}

inline std::shared_ptr<IBinaryStream> CreateCBinaryStream(std::string_view path) {
    return t_CreateCBinaryStream<IBinaryStream>(path, "rb");
}
inline std::shared_ptr<IBinaryStreamW> CreateCBinaryStreamW(std::string_view path) {
    return t_CreateCBinaryStream<IBinaryStreamW>(path, "wb+");
}

} // namespace fs
} // namespace wallpaper

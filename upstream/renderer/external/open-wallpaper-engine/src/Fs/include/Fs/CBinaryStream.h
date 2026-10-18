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
    virtual ~CBinaryStream() { std::fclose(m_file); }

protected:
    CBinaryStream(std::string_view path, std::FILE* file): m_path(path), m_file(file) {}
    virtual usize Write_impl(const void* buffer, usize sizeInBytes) override {
        return std::fwrite(buffer, sizeInBytes, 1, m_file);
    }

public:
    virtual usize Read(void* buffer, usize sizeInBytes) override {
        return std::fread(buffer, 1, sizeInBytes, m_file);
    }
    virtual char* Gets(char* buffer, usize sizeStr) override {
        assert(sizeStr < std::numeric_limits<int>::max());
        return std::fgets(buffer, (int)sizeStr, m_file);
    }
    virtual idx   Tell() const override { return std::ftell(m_file); }
    // Like the other streams, only a position in [0, size] is reachable.
    virtual bool  SeekSet(idx offset) override { return SeekTo(offset); }
    virtual bool  SeekCur(idx offset) override {
        const idx cur = std::ftell(m_file);
        return cur >= 0 && SeekTo(cur + offset);
    }
    virtual bool  SeekEnd(idx offset) override { return SeekTo(Size() + offset); }
    virtual isize Size() const override {
        idx cur = std::ftell(m_file);
        std::fseek(m_file, 0, SEEK_END);
        idx size = std::ftell(m_file);
        std::fseek(m_file, cur, SEEK_SET); // seek back
        return size;
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
    struct Shared : public CBinaryStream<TBinaryStream> {
        Shared(std::string_view path, std::FILE* file): CBinaryStream<TBinaryStream>(path, file) {};
    };
    const std::string text { path };
    std::error_code   failure;
    if (std::filesystem::is_directory(text, failure)) {
        LOG_ERROR("can't open: \'%s\', which is a directory", text.c_str());
        return nullptr;
    }
    auto* file = std::fopen(text.c_str(), mode);
    if (file == NULL) {
        LOG_ERROR("can't open: %s", text.c_str());
        return nullptr;
    }
    auto cb = std::make_shared<Shared>(path, file);
    return cb;
}

inline std::shared_ptr<IBinaryStream> CreateCBinaryStream(std::string_view path) {
    return t_CreateCBinaryStream<IBinaryStream>(path, "rb");
}
inline std::shared_ptr<IBinaryStreamW> CreateCBinaryStreamW(std::string_view path) {
    return t_CreateCBinaryStream<IBinaryStreamW>(path, "wb+");
}

} // namespace fs
} // namespace wallpaper

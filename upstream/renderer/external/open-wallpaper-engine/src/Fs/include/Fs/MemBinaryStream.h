#pragma once

#include <iterator>
#include <memory>
#include <vector>

#include "IBinaryStream.h"
#include "Utils/Logging.h"

namespace wallpaper
{
namespace fs
{

class MemBinaryStream : public IBinaryStream {
public:
    MemBinaryStream(std::vector<uint8_t>&& data): m_pos(0), m_data(std::move(data)) {}
    MemBinaryStream(IBinaryStream&): m_pos(0) {
        // CLEANROOM U60: implement from specs/engine/e7-small-units.md
    }

    virtual ~MemBinaryStream() = default;

public:
    virtual usize Read(void*, usize) {
        // CLEANROOM U61: implement from specs/engine/e7-small-units.md
        return 0;
    }
    virtual char* Gets(char* buffer, usize) {
        // CLEANROOM U62: implement from specs/engine/e7-small-units.md
        return buffer;
    }
    virtual idx  Tell() const { return m_pos; }
    virtual bool SeekSet(idx) {
        // CLEANROOM U63: implement from specs/engine/e7-small-units.md
        return false;
    }
    virtual bool SeekCur(idx) {
        // CLEANROOM U64: implement from specs/engine/e7-small-units.md
        return false;
    }
    virtual bool SeekEnd(idx) {
        // CLEANROOM U65: implement from specs/engine/e7-small-units.md
        return false;
    }
    virtual isize Size() const { return std::ssize(m_data); }

protected:
    virtual usize Write_impl(const void* buffer, usize sizeInByte) { return 0; }

private:
    bool InArea(idx) const noexcept {
        // CLEANROOM U66: implement from specs/engine/e7-small-units.md
        return false;
    }
    idx moveForward(idx) noexcept {
        // CLEANROOM U67: implement from specs/engine/e7-small-units.md
        return 0;
    }

    idx                  m_pos;
    std::vector<uint8_t> m_data;
};

} // namespace fs
} // namespace wallpaper

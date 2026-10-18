#pragma once
#include <memory>
#include <vector>
#include "IBinaryStream.h"

#include "Core/Literals.hpp"

namespace wallpaper
{
namespace fs
{

class LimitedBinaryStream : public IBinaryStream {
public:
    LimitedBinaryStream(std::shared_ptr<IBinaryStream> infs, idx start, isize size)
        : m_pos(0), m_start(start), m_end(start + size), m_infs(infs) {}
    virtual ~LimitedBinaryStream() = default;

private:
    bool CheckInArea(idx) const {
        // CLEANROOM U68: implement from specs/engine/e7-small-units.md
        return false;
    }

    bool SeekInMPos(void) {
        // CLEANROOM U69: implement from specs/engine/e7-small-units.md
        return false;
    }
    bool SeekInPos(idx) {
        // CLEANROOM U70: implement from specs/engine/e7-small-units.md
        return false;
    }
    bool End() const {
        // CLEANROOM U71: implement from specs/engine/e7-small-units.md
        return true;
    }

protected:
    virtual usize Write_impl(const void*, usize) { return 0; }

public:
    virtual usize Read(void*, usize) {
        // CLEANROOM U72: implement from specs/engine/e7-small-units.md
        return 0;
    }
    virtual char* Gets(char* buffer, usize) {
        // CLEANROOM U73: implement from specs/engine/e7-small-units.md
        return buffer;
    }
    virtual idx  Tell() const { return m_pos; }
    virtual bool SeekSet(idx) {
        // CLEANROOM U74: implement from specs/engine/e7-small-units.md
        return false;
    }
    virtual bool SeekCur(idx) {
        // CLEANROOM U75: implement from specs/engine/e7-small-units.md
        return false;
    }
    virtual bool SeekEnd(idx) {
        // CLEANROOM U76: implement from specs/engine/e7-small-units.md
        return false;
    }
    virtual isize Size() const { return m_end - m_start; }

private:
    idx                            m_pos; // 0 < m_pos <= m_end - m_start
    const idx                      m_start;
    const idx                      m_end; // end if m_pos == m_end - m_start
    std::shared_ptr<IBinaryStream> m_infs;
};

} // namespace fs
} // namespace wallpaper

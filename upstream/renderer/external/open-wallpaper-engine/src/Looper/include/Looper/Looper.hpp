#pragma once
#include <memory>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <condition_variable>
#include <string>
#include <thread>
#include <list>
#include <map>
#include <string_view>
#include <variant>
#include <array>

#include "Core/Visitors.hpp"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{
namespace looper
{

enum class status_t
{
    OK                = 0,
    INVALID_OPERATION = -ENOSYS,
    NOT_FOUND         = -ENOENT
};
using handler_id = int32_t;
class Handler;
class Message;

class Looper : NoCopy, public std::enable_shared_from_this<Looper> {
public:
    Looper();
    ~Looper();

    handler_id             registerHandler(const std::shared_ptr<Handler>&);
    void                   unregisterHandler(handler_id id);
    status_t               start();
    void                   stop();
    void                   post(const std::shared_ptr<Message>&);
    const std::string_view name() const;
    void                   setName(std::string_view);
    /// The log scope the looper's thread adopts when it starts; see
    /// `SetWallpaperLogScope`. Takes effect on the next `start()`.
    void                   setLogScope(uint64_t scope);

private:
    std::atomic<bool>       m_running { false };
    std::string             m_name { "unknown" };
    uint64_t                m_log_scope { 0 };
};

class Handler : NoCopy, public std::enable_shared_from_this<Handler> {
public:
    const static handler_id INVALID_HANDLER_ID = 0;
    Handler();
    virtual ~Handler() = default;

    handler_id            id() const;
    std::weak_ptr<Looper> getLooper() const;

protected:
    virtual void onMessageReceived(const std::shared_ptr<Message>&) = 0;

private:
    friend class Looper;
    friend class Message;

    bool setID(handler_id id, std::weak_ptr<Looper> looper);
    // Unbinds the handler again when it still carries `id`, so it may be registered anew.
    void clearID(handler_id id);

    std::atomic<handler_id> m_id;
    std::weak_ptr<Looper>   m_looper;
};

class Message : public std::enable_shared_from_this<Message> {
private:
    Message();
    Message(uint32_t what, const std::shared_ptr<Handler>&);
    friend class Looper;

public:
    static std::shared_ptr<Message> create();
    static std::shared_ptr<Message> create(uint32_t what, const std::shared_ptr<Handler>&);
    uint32_t                        what() const;
    void                            setTarget(const std::shared_ptr<Handler>&);
    void                            setWhat(uint32_t);
    status_t                        post();

    bool setBool(std::string_view, bool);
    bool setInt32(std::string_view, int32_t);
    bool setFloat(std::string_view, float);
    bool setString(std::string_view, std::string);

    bool findBool(std::string_view, bool*) const;
    bool findInt32(std::string_view, int32_t*) const;
    bool findFloat(std::string_view, float*) const;
    bool findString(std::string_view, std::string*) const;

    bool setObject(std::string_view name, const std::shared_ptr<void>&);

    template<typename T>
    bool findObject(std::string_view name, std::shared_ptr<T>* value) const {
        // CLEANROOM UV69
        (void)name;
        (void)value;
        return false;
    }
};

} // namespace looper
} // namespace wallpaper

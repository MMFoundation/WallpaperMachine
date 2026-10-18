// Clean-room implementation from the WallpaperMachine spec e5-text-audio-video-runtime.md; written without access to the original source.
#include "Audio/SoundManager.h"
#include "Audio/SoundStreamFactory.hpp"
#include "miniaudio-wrapper.hpp"
#include "Fs/IBinaryStream.h"
#include "Core/Literals.hpp"
#include "Utils/Logging.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>

using namespace wallpaper;
using namespace wallpaper::audio;

// One mounted stream, decoded ahead of the device on its own worker so a slow or failing
// stream never delays the audio thread or the other streams. The audio thread only copies
// out of a bounded ring (about half a second of frames) and never waits for the worker.
class Channel_Impl : public miniaudio::Channel {
public:
    explicit Channel_Impl(std::shared_ptr<SoundStream> stream): m_ss { std::move(stream) } {}
    ~Channel_Impl() override { StopWorker(); }

    ma_uint64 NextPcmData(void* pData, ma_uint32 frameCount) override {
        const uint32_t channels = m_channels.load(std::memory_order_relaxed);
        if (pData == nullptr || frameCount == 0 || channels == 0) return frameCount;
        auto*        out     = static_cast<float*>(pData);
        const size_t samples = static_cast<size_t>(frameCount) * channels;

        std::unique_lock<std::mutex> lock { m_mutex, std::try_to_lock };
        if (! lock.owns_lock() || m_filled == 0 || m_capacity == 0 || m_ring.empty() ||
            m_layout_channels != channels) {
            std::fill(out, out + samples, 0.0f);
            return frameCount;
        }
        const size_t take = std::min<size_t>(m_filled, frameCount);
        size_t       head = m_head;
        size_t       done = 0;
        while (done < take) {
            const size_t run = std::min(take - done, m_capacity - head);
            std::memcpy(out + done * channels, m_ring.data() + head * channels,
                        run * channels * sizeof(float));
            head = (head + run) % m_capacity;
            done += run;
        }
        m_head = head;
        m_filled -= take;
        std::fill(out + take * channels, out + samples, 0.0f);
        const bool room = m_capacity - m_filled >= m_chunk;
        lock.unlock();
        if (room) m_cv.notify_one();
        return frameCount;
    }

    void PassDeviceDesc(const miniaudio::DeviceDesc& desc) override {
        StopWorker();
        if (m_ss) m_ss->PassDesc({ desc.phyChannels, desc.sampleRate });
        {
            std::lock_guard<std::mutex> lock { m_mutex };
            m_head            = 0;
            m_filled          = 0;
            m_layout_channels = desc.phyChannels;
            m_rate            = desc.sampleRate;
            m_capacity        = std::max<size_t>(desc.sampleRate / 2, 2048);
            m_chunk           = desc.sampleRate == 0
                                    ? 512
                                    : std::clamp<size_t>(desc.sampleRate / 50, 512, 2048);
            if (desc.phyChannels == 0 || desc.sampleRate == 0) {
                m_ring.clear();
                m_capacity = 0;
            } else {
                m_ring.assign(m_capacity * desc.phyChannels, 0.0f);
            }
            m_stop = false;
        }
        m_channels.store(desc.phyChannels, std::memory_order_relaxed);
        if (desc.phyChannels != 0 && desc.sampleRate != 0 && m_ss)
            m_worker = std::thread([this] { WorkerMain(); });
    }

private:
    void StopWorker() {
        {
            std::lock_guard<std::mutex> lock { m_mutex };
            m_stop = true;
        }
        m_cv.notify_all();
        if (m_worker.joinable()) m_worker.join();
    }

    void WorkerMain() {
        std::vector<float> chunk;
        for (;;) {
            size_t   frames;
            uint32_t channels;
            {
                std::unique_lock<std::mutex> lock { m_mutex };
                m_cv.wait(lock, [this] { return m_stop || m_capacity - m_filled >= m_chunk; });
                if (m_stop) return;
                frames   = m_chunk;
                channels = m_layout_channels;
            }
            chunk.assign(frames * channels, 0.0f);
            // A short read keeps the rest silent; a read of 0 (ended, empty or failing
            // stream) still queues a chunk of silence, which paces the worker.
            m_ss->NextPcmData(chunk.data(), static_cast<uint32_t>(frames));
            {
                std::lock_guard<std::mutex> lock { m_mutex };
                if (m_stop) return;
                size_t tail = (m_head + m_filled) % m_capacity;
                size_t done = 0;
                while (done < frames) {
                    const size_t run = std::min(frames - done, m_capacity - tail);
                    std::memcpy(m_ring.data() + tail * channels, chunk.data() + done * channels,
                                run * channels * sizeof(float));
                    tail = (tail + run) % m_capacity;
                    done += run;
                }
                m_filled += frames;
            }
        }
    }

    std::shared_ptr<SoundStream> m_ss;

    std::mutex              m_mutex;
    std::condition_variable m_cv;
    std::thread             m_worker;
    std::vector<float>      m_ring;
    size_t                  m_head { 0 };
    size_t                  m_filled { 0 };
    size_t                  m_capacity { 0 };
    size_t                  m_chunk { 512 };
    uint32_t                m_layout_channels { 0 };
    uint32_t                m_rate { 0 };
    bool                    m_stop { false };
    std::atomic<uint32_t>   m_channels { 0 };
};

std::unique_ptr<SoundStream>
wallpaper::audio::CreateSoundStream(std::shared_ptr<wallpaper::fs::IBinaryStream> stream,
                                    const SoundStream::Desc&                      desc,
                                    SoundStream::Options options) {
    std::string error;
    auto        sound = CreateSceneSoundStream(std::move(stream), &error, options);
    if (sound == nullptr) {
        LOG_ERROR("failed to create sound stream: %s", error.c_str());
        return nullptr;
    }
    sound->PassDesc(desc);
    return sound;
}

class SoundManager::impl : NoCopy, NoMove {
public:
    explicit impl(OutputBackend backend) {
        if (backend == OutputBackend::Null) {
            const ma_backend backends[] = { ma_backend_null };
            if (ma_context_init(backends, 1, nullptr, &context) == MA_SUCCESS) {
                context_inited = true;
            } else {
                LOG_ERROR("can't init null audio context");
            }
        }
        device.emplace(context_inited ? &context : nullptr);
    }
    ~impl() {
        device.reset();
        if (context_inited) ma_context_uninit(&context);
    }
    ma_context                       context {};
    bool                             context_inited { false };
    std::optional<miniaudio::Device> device;
};

SoundManager::SoundManager(OutputBackend backend): pImpl(std::make_unique<impl>(backend)) {}
SoundManager::~SoundManager() {}

void SoundManager::MountStream(std::unique_ptr<SoundStream>&& ss) {
    MountStream(std::shared_ptr<SoundStream>(std::move(ss)));
}

void SoundManager::MountStream(std::shared_ptr<SoundStream> ss) {
    pImpl->device->MountChannel(std::make_unique<Channel_Impl>(std::move(ss)));
}

void SoundManager::Play() { pImpl->device->Start(); }
void SoundManager::Pause() { pImpl->device->Stop(); }

void  SoundManager::UnMountAll() { pImpl->device->UnmountAll(); }
float SoundManager::Volume() const { return pImpl->device->Volume(); }

bool SoundManager::Muted() const { return pImpl->device->Muted(); }
void SoundManager::SetMuted(bool v) { pImpl->device->SetMuted(v); }
void SoundManager::SetVolume(float v) { pImpl->device->SetVolume(v); }
bool SoundManager::OutputStarted() const { return pImpl->device->IsStarted(); }

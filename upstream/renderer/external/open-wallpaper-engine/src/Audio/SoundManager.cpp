#include "Audio/SoundManager.h"
#include "Audio/SoundStreamFactory.hpp"
#include "miniaudio-wrapper.hpp"
#include "Fs/IBinaryStream.h"
#include "Core/Literals.hpp"
#include "Utils/Logging.h"

#include <algorithm>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>

using namespace wallpaper;
using namespace wallpaper::audio;

class Channel_Impl : public miniaudio::Channel {
public:
    explicit Channel_Impl(std::shared_ptr<SoundStream> stream): m_ss { std::move(stream) } {}

    ma_uint64 NextPcmData(void* pData, ma_uint32 frameCount) override {
        (void)pData;
        return frameCount; // CLEANROOM MV34
    }

    void PassDeviceDesc(const miniaudio::DeviceDesc& desc) override {
        (void)desc; // CLEANROOM MV35
    }

private:
    std::shared_ptr<SoundStream> m_ss;
};

std::unique_ptr<SoundStream>
wallpaper::audio::CreateSoundStream(std::shared_ptr<wallpaper::fs::IBinaryStream> stream,
                                    const SoundStream::Desc&                      desc,
                                    SoundStream::Options options) {
    (void)stream;
    (void)desc;
    (void)options;
    return nullptr; // CLEANROOM MV36
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

#pragma once
#include "VulkanPass.hpp"
#include <optional>
#include <string>

#include "Vulkan/Device.hpp"

#include "RenderCommon/ScenePassInfo.hpp"
#include "SpecTexs.hpp"

namespace wallpaper
{
namespace vulkan
{

class PrePass : public VulkanPass, public ScenePassInfo {
public:
    struct Desc {
        // in
        std::string result { SpecTex_Default };
        VkImageLayout layout { VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        bool transparent { false };

        // prepared
        ImageParameters vk_result;
        VkClearValue    clear_value;
    };

    const Desc& desc() const { return m_desc; }
    PrePass(const Desc&);
    virtual ~PrePass();

    // void setClearValue(vk::ClearValue);

    std::optional<ClearPassInfo> clearInfo() const override {
        return ClearPassInfo { m_desc.result, m_desc.transparent };
    }

    void prepare(Scene&, const Device&, RenderingResources&) override;
    bool updateFrame(const Device&, RenderingResources&) override;
    VkResult execute(const Device&, RenderingResources&) override;
    void destory(const Device&, RenderingResources&) override;

private:
    Desc m_desc;
    const Scene* m_scene { nullptr };
};

} // namespace vulkan
} // namespace wallpaper

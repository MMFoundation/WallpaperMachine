#pragma once

#include "Video/VideoTextureSource.hpp"

#include <string>

struct AVBufferRef;
struct AVFrame;

namespace wallpaper::video
{

bool CreateVideoToolboxDeviceContext(AVBufferRef** hw_device_ctx, std::string* error);
bool ExtractVideoToolboxFrame(const AVFrame* frame,
                              VideoTextureFrame* out,
                              std::string* error);
bool ExtractAppleVideoFrame(const AVFrame* frame,
                            VideoTextureFrame* out,
                            std::string* error);

} // namespace wallpaper::video

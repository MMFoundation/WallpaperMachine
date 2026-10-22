find_package(OpenGL REQUIRED)
find_package(Threads REQUIRED)
find_package(Freetype REQUIRED)
pkg_check_modules(LZ4 REQUIRED IMPORTED_TARGET liblz4)

include(TestBigEndian)
test_big_endian(ENDIAN)
if(ENDIAN)
  add_compile_definitions(WP_BIG_ENDIAN)
endif()

if(APPLE)
  # R1-B2a: to be written from spec
endif()

set(warn_opts
    -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wno-unused-variable
    # A command posted to a looper handler and missing from its switch compiles,
    # links, runs and does nothing: `CMD_SET_RENDER_SCALE` reached no handler
    # from the day it was added. The handler switches carry no `default`, so
    # this promotes exactly that omission to a build failure without promoting
    # unrelated warnings.
    -Werror=switch
    CACHE INTERNAL "")

include_directories(.)

set(PLATFORM_APPLE_SOURCES)
if(APPLE)
  list(APPEND PLATFORM_APPLE_SOURCES
       Platform/Apple/VideoFrameInterop.mm
       Platform/Apple/SceneWallpaperBindings.mm)
endif()

add_subdirectory(Fs)
add_subdirectory(Utils)
add_subdirectory(Audio)
add_subdirectory(Scene)
add_subdirectory(Looper)
add_subdirectory(Scene/Timer)
add_subdirectory(Scene/Particle)
add_subdirectory(Scene/RenderGraph)
add_subdirectory(Scene/RenderCommon)
add_subdirectory(Scene/MetalRender)

add_library(
  ${PROJECT_NAME} STATIC
  Scene/WPJson.cpp
  Scene/WPPkgFs.cpp
  Type.cpp
  Runtime/CameraPath.cpp
  Runtime/DynamicValue.cpp
  # R1-B2b: to be written from spec
  Video/ClockedVideoSource.cpp
  Video/VideoColorConversion.cpp
  Video/VideoContainerProbe.cpp
  Video/VideoDecodePump.cpp
  Video/VideoFramePacing.cpp
  Video/VideoMedia.cpp
  Video/NativeVideoBackend.cpp
  Video/VideoTextureSourceFactory.cpp
  ${PLATFORM_APPLE_SOURCES}
  SceneSourceResolver.cpp
  Scene/SceneWallpaper.cpp)

add_library(wescene::renderer ALIAS ${PROJECT_NAME})

# This target owns the looper handlers. Their switches carry no `default`, so a
# command that is posted and never dispatched — which is what happened to
# `CMD_SET_RENDER_SCALE` from the day it was added — stops the build instead of
# adding one more warning line nobody reads. Only this class is promoted; the
# rest of `warn_opts` is deliberately not applied to this target.
target_compile_options(${PROJECT_NAME} PRIVATE -Werror=switch)

set(InteralLib
    wpAudio
    wpLooper
    wpMetalRender
    wpRenderCommon
    wpFs
    wpScene
    wpRGraph
    wpParticle
    wpTimer)

# This project's own container readers (Renderer/Media), added by the top-level
# CMakeLists.txt from the repository checkout the engine now depends on.
if(NOT TARGET wmMedia)
  message(FATAL_ERROR "wescene-renderer needs Renderer/Media (target wmMedia): "
                      "configure it from a full WallpaperMachine checkout")
endif()
set(WESCENE_MEDIA_LIBS wmMedia)
if(APPLE)
  # The VideoToolbox layer of the same readers: format descriptions and a
  # decoder the native video backend plays through.
  if(NOT TARGET wmMediaApple)
    message(FATAL_ERROR "wescene-renderer needs Renderer/Media/Apple (target wmMediaApple)")
  endif()
  list(APPEND WESCENE_MEDIA_LIBS wmMediaApple)
endif()

# The still preview a wallpaper that cannot be drawn shows (Renderer/Surface).
if(NOT TARGET wmSurface)
  message(FATAL_ERROR "wescene-renderer needs Renderer/Surface (target wmSurface): "
                      "configure it from a full WallpaperMachine checkout")
endif()

target_link_libraries(
  ${PROJECT_NAME}
  PUBLIC wpUtils
  PRIVATE ${InteralLib} ${WESCENE_MEDIA_LIBS} wmSurface nlohmann_json::nlohmann_json quickjs::quickjs PkgConfig::LZ4
          Freetype::Freetype
          ${CMAKE_THREAD_LIBS_INIT} ${CMAKE_DL_LIBS})

if(APPLE)
  target_link_libraries(
    ${PROJECT_NAME}
    PUBLIC
      ${CORE_AUDIO_FRAMEWORK}
      ${AUDIO_TOOLBOX_FRAMEWORK}
      ${AUDIO_UNIT_FRAMEWORK}
      ${CORE_MEDIA_FRAMEWORK}
      ${CORE_TEXT_FRAMEWORK}
      ${CORE_VIDEO_FRAMEWORK}
      ${ACCELERATE_FRAMEWORK}
      ${FOUNDATION_FRAMEWORK}
      ${IOSURFACE_FRAMEWORK}
      ${METAL_FRAMEWORK}
      ${VIDEOTOOLBOX_FRAMEWORK})
endif()

target_include_directories(${PROJECT_NAME} PUBLIC .)
# R1-B2c: to be written from spec

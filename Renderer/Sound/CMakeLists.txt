# wmSound: this project's own sound decoding path (remix, resample, loop, and the
# decoders that feed it). The pure parts (PcmPipeline, Resampler, ChannelRemix)
# are C++17 with no dependency but wmMedia's ByteSource; the decoders behind
# Sound/Apple and Sound/Vorbis use AudioToolbox and a vendored public-domain
# stb_vorbis. The engine build (upstream/renderer/external/open-wallpaper-engine/
# CMakeLists.txt) includes this directory for the library and Sound/tests for the
# test executables.
set(WM_SOUND_SOURCES
    ChannelRemix.cpp
    PcmPipeline.cpp
    Resampler.cpp
)
if(APPLE)
    list(APPEND WM_SOUND_SOURCES Apple/AppleDecoder.cpp)
endif()

add_library(wmSound STATIC ${WM_SOUND_SOURCES})
set_target_properties(wmSound PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS OFF
    POSITION_INDEPENDENT_CODE ON)
# Includes are written as "Sound/<Header>.hpp", relative to Renderer/.
target_include_directories(wmSound PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/..")
target_link_libraries(wmSound PUBLIC wmMedia)
if(APPLE)
    target_link_libraries(wmSound PUBLIC "-framework AudioToolbox" "-framework CoreFoundation")
endif()
target_compile_options(wmSound PRIVATE
    -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)

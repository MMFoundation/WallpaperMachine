cmake_minimum_required(VERSION 3.14)
project(wescene-renderer)

if(APPLE)
    enable_language(OBJCXX)
endif()

# R1-B1a: to be written from spec

# This project's own container readers (wmMedia). The sources live outside
# upstream/, in the repository's top-level Renderer/Media, and are pure C++17 with
# no dependency on anything else here. The engine links it, so it has to be
# configured from a full checkout.
get_filename_component(
    WESCENE_MEDIA_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../../Renderer/Media" ABSOLUTE)
if(EXISTS "${WESCENE_MEDIA_DIR}/CMakeLists.txt")
    add_subdirectory("${WESCENE_MEDIA_DIR}" "${CMAKE_BINARY_DIR}/Renderer/Media")
    # Its Apple platform layer (ObjC++ over VideoToolbox) is a library of its own.
    if(APPLE AND EXISTS "${WESCENE_MEDIA_DIR}/Apple/CMakeLists.txt")
        add_subdirectory("${WESCENE_MEDIA_DIR}/Apple" "${CMAKE_BINARY_DIR}/Renderer/Media/Apple")
    endif()
endif()

# This project's own sound path (wmSound): remixing, resampling, looping and the
# decoders behind scene sounds, in the repository's top-level Renderer/Sound. It
# needs wmMedia's ByteSource, so it is only built where wmMedia is.
get_filename_component(
    WESCENE_SOUND_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../../Renderer/Sound" ABSOLUTE)
if(TARGET wmMedia AND EXISTS "${WESCENE_SOUND_DIR}/CMakeLists.txt")
    add_subdirectory("${WESCENE_SOUND_DIR}" "${CMAKE_BINARY_DIR}/Renderer/Sound")
endif()

# This project's own surface pieces (wmSurface): the still preview a wallpaper
# that cannot be drawn shows instead of an empty layer, in the repository's
# top-level Renderer/Surface. Self-contained: ImageIO and Core Animation only.
get_filename_component(
    WESCENE_SURFACE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../../Renderer/Surface" ABSOLUTE)
if(EXISTS "${WESCENE_SURFACE_DIR}/CMakeLists.txt")
    add_subdirectory("${WESCENE_SURFACE_DIR}" "${CMAKE_BINARY_DIR}/Renderer/Surface")
endif()

# R1-B1b: to be written from spec
option(
    RUST_SHADER_FFI
    "Compile the Rust shader bridge against externally resolved rs_shader_* symbols"
    ${_wescene_rust_shader_ffi_default})

add_subdirectory(src)

if(BUILD_TESTS)
    include(CTest)
    add_subdirectory(tests)
    # wmMedia's tests use the googletest that tests/ just fetched.
    if(TARGET wmMedia)
        add_subdirectory("${WESCENE_MEDIA_DIR}/tests" "${CMAKE_BINARY_DIR}/Renderer/Media/tests")
    endif()
    if(TARGET wmSound)
        add_subdirectory("${WESCENE_SOUND_DIR}/tests" "${CMAKE_BINARY_DIR}/Renderer/Sound/tests")
    endif()
    if(TARGET wmSurface)
        add_subdirectory("${WESCENE_SURFACE_DIR}/tests" "${CMAKE_BINARY_DIR}/Renderer/Surface/tests")
    endif()
endif()

# The waywallen host, QML helper and standalone viewer were removed from this
# vendored copy (macOS app embeds the library directly); see upstream/provenance.json.

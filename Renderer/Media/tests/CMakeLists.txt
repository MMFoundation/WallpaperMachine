# Test executables for wmMedia. They need GTest::gtest_main, which the engine's
# tests/ directory fetches (or the standalone build in ../CMakeLists.txt does).
# Binaries land in <build>/tests next to the engine's own, where
# scripts/check_renderer.py runs them from.
include(GoogleTest)

function(wm_media_test name)
    add_executable(${name} ${ARGN})
    target_link_libraries(${name} PRIVATE wmMedia GTest::gtest_main)
    set_target_properties(${name} PROPERTIES
        CXX_STANDARD 17
        CXX_STANDARD_REQUIRED ON
        CXX_EXTENSIONS OFF
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/tests")
    target_compile_options(${name} PRIVATE
        -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow)
    gtest_discover_tests(${name} PROPERTIES TIMEOUT 120 DISCOVERY_TIMEOUT 60)
endfunction()

wm_media_test(media_core_tests core_tests.cpp)

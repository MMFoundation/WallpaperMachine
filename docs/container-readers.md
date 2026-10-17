# Container readers

`Renderer/Media/` holds the project's own readers for video containers. They are
pure C++17 with no Apple, FFmpeg or other third-party dependency, written from
the public ISO/IEC 14496-12/-15 and Matroska/EBML (RFC 8794) specifications, so
the same sources can be compiled into the app, the sandboxed lock-screen
extension and the test binaries. They only locate and describe samples; decoding
is another layer's job.

Nothing in the app links them yet: `wmMedia` is a static library that only its
own tests use. Where they sit in the build and the tree is in
[repository-layout.md](repository-layout.md).

## Layout

| File | Holds |
|---|---|
| `Error.hpp/.cpp` | `Error` (kind, message, byte offset) that every reader fills instead of throwing |
| `Checked.hpp/.cpp` | overflow-checked add/sub/mul and an overflow-free rescale for sizes and times read from files |
| `Rational.hpp/.cpp` | an exact fraction, so a frame period such as 1001/30000 s stays exact |
| `ByteSource.hpp/.cpp` | where a reader gets its bytes: `size()`, `readAt()` and an optional zero-copy `view()`. `MakeMemoryByteSource` shares ownership of the bytes (a vector, or any buffer plus its owner, so a video payload embedded in a package needs no temp file); `OpenFileByteSource` reads through a 64 KiB window with `pread` and never maps the file, so a file truncated while open gives a short read, not a fault. Reads past the end are shortened, never faulted; both are safe to call from several threads |
| `ByteReader.hpp` | a bounds-checked big-endian cursor over bytes in memory; a short read latches a failure and returns 0 |
| `tests/` | googletest executables, defined with `wm_media_test()` in `tests/CMakeLists.txt` |

## Build and tests

The engine's CMake (`upstream/renderer/external/open-wallpaper-engine/CMakeLists.txt`)
includes `Renderer/Media` for the library and `Renderer/Media/tests` for the
executables, which land in `<build>/tests` beside the engine's own and are
registered in `scripts/check_renderer.py` (`REGRESSION_BINARIES`);
`scripts/tests/test_check_renderer.py` fails when a `wm_media_test()` is not
registered. They need no GPU, window or media file.

`cmake -S Renderer/Media -B <dir>` configures the readers alone, with a fetched
googletest; add `-DWM_MEDIA_SANITIZE=address,undefined` for a sanitizer build.

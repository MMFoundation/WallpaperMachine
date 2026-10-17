# Container readers

`Renderer/Media/` holds the project's own readers for video containers. They are
pure C++17 with no Apple, FFmpeg or other third-party dependency, written from
the public ISO/IEC 14496-12/-15 and Matroska/EBML (RFC 8794) specifications, so
the same sources can be compiled into the app, the sandboxed lock-screen
extension and the test binaries. They only locate and describe samples; decoding
is another layer's job.

`wmMedia` is a static library the scene engine links. Today the scene texture
parser uses the ISO-BMFF reader to learn the size and length of an MP4 or
QuickTime video from memory (`Video/VideoContainerProbe.cpp`), where it used to
write the payload to a temporary file for FFmpeg; any other payload, and one the
reader refuses, is still probed by FFmpeg. Where the readers sit in the build and
the tree is in [repository-layout.md](repository-layout.md).

## Layout

| File | Holds |
|---|---|
| `Error.hpp/.cpp` | `Error` (kind, message, byte offset) that every reader fills instead of throwing |
| `Checked.hpp/.cpp` | overflow-checked add/sub/mul and an overflow-free rescale for sizes and times read from files |
| `Rational.hpp/.cpp` | an exact fraction, so a frame period such as 1001/30000 s stays exact |
| `ByteSource.hpp/.cpp` | where a reader gets its bytes: `size()`, `readAt()` and an optional zero-copy `view()`. `MakeMemoryByteSource` shares ownership of the bytes (a vector, or any buffer plus its owner, so a video payload embedded in a package needs no temp file); `OpenFileByteSource` reads through a 64 KiB window with `pread` and never maps the file, so a file truncated while open gives a short read, not a fault. Reads past the end are shortened, never faulted; both are safe to call from several threads |
| `DisplayMatrix.hpp/.cpp` | the `tkhd` 3x3 matrix as stored, and `ClassifyDisplayMatrix` for the eight quarter-turn/mirror orientations |
| `VideoTypes.hpp/.cpp` | what every reader reports: `VideoStreamInfo` (codec fourcc and raw config record, coded and display size, matrix, colour, bit depth, timescale, duration, exact frame periods) and the per-frame `Sample` |
| `CodecConfig.hpp/.cpp` | bit depth (and VP9 colour) read out of an `avcC`, `hvcC`, `av1C` or `vpcC` record; a record too short for its type is refused |
| `IsoBmff/IsoBmffReader.hpp/.cpp` | the MP4/QuickTime reader, below |
| `KeyframeIndex.hpp` | keyframe seeking over a `Sample` table, shared by both readers |
| `Matroska/Ebml.hpp` | EBML ids, sizes, integers, floats and strings (RFC 8794) |
| `Matroska/MatroskaReader.hpp/.cpp` | the Matroska/WebM reader, below |
| `Matroska/Vp9Header.hpp/.cpp` | the VP9 uncompressed header: profile, bit depth, colour space, subsampling and size of a key frame |
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

## ISO-BMFF (MP4, MOV)

`IsoBmffReader::Open(source, &error)` reads the first enabled video track of a
progressive file. The `mdat` may precede or follow `moov`; 64-bit and
to-end-of-file box sizes are understood. It returns a flat sample table (offset,
size, dts, pts, duration, sync, in decode order) and a `VideoStreamInfo`.

- **Sample tables:** `stsd` (avc1, avc3, hvc1, hev1, av01, vp09 with their
  `avcC`/`hvcC`/`av1C`/`vpcC` record exposed as the box payload, byte for byte;
  any other video entry is reported by type alone; `encv` is unsupported),
  `stts`, `ctts` (version 0 and 1, read as signed so negative offsets work),
  `stss` (absent means every sample is sync), `stsz`/`stz2` (4, 8 and 16 bit),
  `stsc`, `stco`/`co64`.
- **Timing:** `mdhd` timescale; an edit list of at most one leading empty edit
  and one normal media segment moves presentation times by the empty duration
  minus the segment's media start, so pts are what a player shows (a negative pts
  is pre-roll). `durationTicks` is the edit list's length, else `mdhd`, else `tkhd`,
  else the end of the last sample. `minFramePeriod` and `avgFramePeriod` are exact
  fractions of a second from the sample durations.
- **Picture:** coded size from the sample entry, display size and matrix from
  `tkhd`, `colr` (`nclx` and `nclc`), `pasp`, and the bit depth the config record
  states (a `vpcC` also supplies colour when there is no `colr`).
- **Seeking:** `findKeyframeAtOrBefore(pts)` binary-searches the sync samples by
  presentation time (a linear scan when the file's sync samples are not in
  presentation order) and answers the first sync sample for a time before all of
  them.
- **Refused with a reason (`Unsupported`):** fragmented files (`moof`, `styp`,
  `mvex`: "fragmented MP4 not supported"), an edit list with several media
  segments or a rate other than 1, encrypted entries, a track that changes sample
  description, a file with no video track. A corrupt table, a cut `moov` or a size
  beyond the limits is `Corrupt`, `Truncated` or `LimitExceeded`; input that is not
  MP4 at all is `NotThisFormat`.
- **Tolerated, with a warning in `warnings()`:** sample data cut short (the whole
  samples before the cut stay), a `ctts` or chunk table shorter than `stsz`, an edit
  list with no media segment.
- **Limits (`IsoBmffLimits`):** `moov` 128 MiB, 4,000,000 samples, 100,000
  top-level boxes, 256 tracks, 4096 edits, 1 MiB config record, 256 MiB per
  `readSample`. Every count read from the file is checked against the box that
  holds it before anything is allocated.

## Matroska and WebM

`MatroskaReader::Open(source, &error)` makes one sequential pass over the Segment,
reading element and block headers only (frame payloads are skipped by size), and
indexes every frame of every video and audio track. Cues are ignored on purpose:
the index gives exact durations and frame periods, keyframe seeking without Cues,
and works when Cues are missing, wrong or after the media.

- **Structure:** EBML header (`DocType` must be `webm` or `matroska`,
  `DocTypeReadVersion` at most 4, id length at most 4 and size length at most 8),
  `Segment` and `Cluster` of unknown size (a Cluster then ends at the next
  Segment-level element), `Info` (`TimecodeScale`, `Duration`), `Tracks`
  (including `Video`, `Colour`, `Projection`, `Audio`, `ContentEncodings`),
  `SimpleBlock`, `BlockGroup` (`Block`, `BlockDuration`, `ReferenceBlock`,
  `DiscardPadding`), Xiph, EBML and fixed lacing. Tracks must come before the
  first Cluster. `BlockAdditions` are ignored, so a VP9-alpha file plays opaque.
- **Codecs:** `V_VP9`, `V_AV1`, `V_MPEG4/ISO/AVC`, `V_MPEGH/ISO/HEVC` for video and
  `A_OPUS`, `A_VORBIS`, `A_AAC`, `A_MPEG/L3` for audio, each with `CodecPrivate`
  exposed verbatim (an `avcC`, `hvcC` or `av1C` record for video, so H.264 and
  HEVC in Matroska reach a decoder exactly like MP4). `V_VP8` and any other id
  are unsupported and named in the error (`unsupported: video codec V_VP8 is not
  supported`). The reader only reports codec and configuration; whether the
  Mac can decode it (AV1 needs hardware decode, for one) is the adapter's call.
- **Video track:** the first enabled video track whose codec is supported; `Open`
  fails with `Unsupported` when there is none. A VP9 track has no `vpcC` in WebM,
  so the first key frame's header is parsed (`vp9KeyFrame()`) for the profile, bit
  depth, colour space and size. Colour comes from the `Colour` element, the
  display matrix from a `ProjectionPoseRoll` of whole quarter turns (the sign
  matches what FFmpeg writes and reads), the pixel aspect ratio from
  `DisplayWidth`/`DisplayHeight`.
- **Times:** nanoseconds. Matroska stores only presentation times, so `dts` of a
  video sample is derived: the sorted presentation times, moved earlier by the
  least amount that keeps every `dts` at or before its `pts` (equal to `pts` when
  nothing is reordered). The index, not `Info.Duration`, decides `durationTicks`
  (the end of the last frame; `Info.Duration` is only used for a headers-only open
  and stays available as `info().infoDurationNs`).
- **Content encodings:** header stripping is understood (`readSample`/`readPacket`
  put the stripped bytes back); encryption, zlib/bzip2/lzo compression and
  anything else is `Unsupported` for that track.
- **Damage:** a problem inside the media data (a corrupt or cut block, a bad lace
  table, an oversized frame) ends the index and keeps what was read, with a
  warning, once at least one video key frame is indexed; before that it is an
  error. Limits and unsupported features always fail the open.
- **Limits (`MatroskaLimits`):** 16 MiB of header data, 64 tracks, 1 MiB
  `CodecPrivate`, 256 frames per laced block, 64 MiB per frame (a video frame is
  also capped at the larger of 64 KiB and width x height x 4), 4,000,000 indexed
  frames, 60 s of scanning, 256 MiB per `readSample`. `MatroskaOptions::buildIndex
  = false` reads the headers only, to probe tracks without scanning the file.

## Tests

| Binary | Covers |
|---|---|
| `media_core_tests` | error, checked arithmetic, fractions, byte cursor, memory and file byte sources |
| `media_isobmff_tests` | the ISO-BMFF reader on files built in memory by `tests/mp4_builder.hpp`: tables and layouts, every codec entry, composition offsets, edit lists, all eight orientations, seeking, fragmented/unsupported/oversized/truncated/junk input and a deterministic random-mutation loop; plus corpus A/B checks: the bundled starter wallpaper against recorded expectations, and the local library against `ffprobe` |
| `media_matroska_tests` | the Matroska reader on files built in memory by `tests/mkv_builder.hpp`: the index, SimpleBlock and BlockGroup, lacing, unknown-size Segment and Clusters, Cues present or absent, EBML header checks, codecs and encodings, limits, truncation at every length, malformed elements and a deterministic random-mutation loop; the VP9 header parser on the first frames of real libvpx clips; plus a corpus A/B check of `.webm`/`.mkv` files against `ffprobe` |

The corpus checks read the local wallpaper library, or the folder in
`WALLPAPER_MACHINE_VIDEO_ROOT`, and compare with `ffprobe` when it is installed
(`WALLPAPER_MACHINE_FFPROBE` overrides its path). With no file they skip with a
printed reason; a skip is not a pass. Nothing is written, and only the file's
base name is printed.

The mutation loops are most useful under sanitizers, which the routine gate does
not run. To run all three binaries that way:

```sh
cmake -S Renderer/Media -B artifacts/media/asan -G Ninja -DWM_MEDIA_SANITIZE=address,undefined
cmake --build artifacts/media/asan
artifacts/media/asan/tests/media_matroska_tests
```

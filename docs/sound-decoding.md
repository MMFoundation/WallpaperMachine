# Sound decoding

How a scene's sounds become audio for the output device, and what the project
writes itself versus asks the system for. The code is `Renderer/Sound` (`wmSound`,
a static library the scene engine's CMake includes) plus a thin layer in the
engine's `src/Audio`. Nothing here plays audio in a test: every test reads
samples from a stream or uses miniaudio's null backend, which discards them.

## The path

A scene sound reaches the device in four steps.

1. **`CreateSceneSoundStream`** (`src/Audio/SoundStreamFactory`) is the only
   place that decides which decoder serves a file. The package hands it the
   file's bytes through the engine's virtual file system; the factory reads the
   first four bytes, not the file name, and sends an Ogg file (`OggS`) to the Ogg
   Vorbis decoder and everything else to AudioToolbox.
2. **A decoder** (`Renderer/Sound`, a `PcmDecoder`) turns the file into
   interleaved 32-bit float frames at the file's own channel count and sample
   rate, from the first frame to the last, and back to the first on `rewind()`.
   It does nothing else.
3. **`PcmPipeline`** converts those frames to the device: channels first when
   mixing down, resampling at the smaller channel count, channels last when
   mixing up; a loop rewinds the decoder and starts over. One pass of a sound is
   its decoded frames resampled with the tail finished, so a loop is that pass
   over and over with no gap and no overlap at the seam. A sound with no frames
   ends even when it loops.
4. **`PcmSoundStream`** (`src/Audio`) is the `SoundStream` the output worker
   reads: it zero-fills what the pipeline did not produce, restarts the sound
   from its first frame when the device layout changes, and logs a failure once.

A sound the engine cannot decode (an unsupported codec, a file that is not
audio, a file whose headers are cut off) is not played: the layer stays silent
and the log names the reason. A file cut short in its audio plays what is there.

## What is ours and what is the system's

| Piece | Where | Notes |
|---|---|---|
| Channel remix | `ChannelRemix` | The conventional downmix: matching positions pass through, the centre folds into left and right (and left and right into a mono centre) at -3 dB, surrounds fold forward at -3 dB, the low-frequency channel is dropped when it has nowhere to go. Layouts for 1 to 8 channels. Mono to stereo is therefore -3 dB per channel, as FFmpeg's resampler did |
| Resampling | `Resampler` | A polyphase windowed-sinc filter (Kaiser window, beta 9, 32 taps per output frame when raising the rate and proportionally more when lowering it, up to an input rate of about 62 times the output's: `Resampler::Supports` and `PcmPipeline::Supports` say no beyond that, and the sound stays silent with a log line rather than build a filter table of gigabytes). The cutoff is 97 percent of the output Nyquist frequency or the input's, whichever is lower, so raising the rate keeps the whole input band. Positions are integers: ratios such as 44.1 to 48 kHz use exact filter phases and nothing drifts. A pass of `n` frames produces exactly `ceil(n * out / in)` frames, and the first output frame lines up with the first input frame |
| Looping, end of sound | `PcmPipeline` | As above |
| WAV, AIFF, CAF, MP3, FLAC, AAC and the rest of AudioFile's formats | `Apple/AppleDecoder` | `AudioFileOpenWithCallbacks` over the package's bytes (a `media::ByteSource`, read on demand), then `ExtAudioFile` with a 32-bit float client format at the file's own layout, so the system changes the sample format and nothing else. A file whose format is not recognised by sniffing is retried with each likely type named. With `audioOptional`, an MP4 or MOV with no audio track returns no decoder and no error (a silent video is not a failure); anything else AudioToolbox cannot read is an error |

AudioToolbox's MP3 decoder is 16-bit and saturates at full scale; FFmpeg's float
decode kept peaks above full scale. Of the 87 MP3 sounds in the local library, 25
decode above 1.0 in FFmpeg (by up to 3 dB), and AudioToolbox clips those peaks at
1.0. It only matters when the wallpaper's volume is below full: the device clips
the same samples at full volume. There is no AudioToolbox setting for it, so a
decoder that keeps those peaks would have to be written.

## MP3 gapless playback

AudioToolbox follows the file's own gapless tag: the encoder delay and padding of
a LAME/Xing header give the length (`frames * 1152 - delay - padding`) and the
start, so a loop has no silence at the seam. A file without a tag decodes in full
with the decoder's own delay removed. FFmpeg's answer differed for files whose
tag claims too little padding to flush the decoder (it lost the last 529 frames)
and for the odd file whose tag it ignored. On the local library (103 scene sounds)
the decoded length equals FFmpeg's for 94; the other 9 are MP3s whose tag claims
no padding (AudioToolbox is 529 frames longer, the frames FFmpeg dropped) and one
whose tag FFmpeg ignored (AudioToolbox is 2160 frames shorter, as the tag says).

## Tests

- `audio_tests` (`tests/audio/sound_stream_test.cpp`): what a scene sound decodes
  to, through `CreateSoundStream`, whichever decoder sits behind it. WAV in every
  sample format, remixing, resampling lengths and tone, loop seams, end of file,
  refused and cut-short input, and the output worker on the null backend. The
  tiny MP3, Ogg Vorbis and FLAC files are in `sound_fixture_data.hpp`; their
  expectations were recorded from the FFmpeg decoder that served scene sounds
  before.
- `sound_core_tests` (`Renderer/Sound/tests`): the resampler (including which
  ratios are supported and a ratio that skips more input than one push brings),
  the remix and the pipeline over synthetic decoders, with no Apple framework or
  file.
- `sound_apple_tests` (`Renderer/Sound/tests`): the AudioToolbox decoder over a
  generated WAV and two tiny MP4 files: the reported layout, frames in any chunk
  size, rewind, the audio track of a video, and what it says about input that is
  not audio or has none.

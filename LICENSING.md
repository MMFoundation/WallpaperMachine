# Licensing, Supporter model and distribution status

Recorded: 2026-10-17 (first recorded 2026-09-14).
Status: source policy decided (GPL-2.0-only); Supporter model decided (a free
signed download, and a one-time Supporter purchase for a sponsor place and
priority support); **binary distribution is not cleared**: the Apache-2.0
and GPL-3.0-family components that blocked it were removed from the link closure on
2026-10-17, but the items under [Before any distribution](#before-any-distribution)
are open (see [Remaining blockers](#remaining-blockers)).

This document is the project's own record of what it has checked and decided.
It is not legal advice and it does not claim clearance that has not been
obtained. Where a statement below rests on a third party's text, the primary
source is linked.

## Summary

| Question | Answer |
|---|---|
| Under which license is this repository's source offered? | GNU GPL version 2 only, the text in the root [`LICENSE`](LICENSE). See [Source license](#source-license-gpl-20-only). |
| Is anything sold? | Only the Supporter purchase: a one-time payment for a sponsor place and priority support. The signed download is free and no copy of the software is sold. See [Supporter model](#supporter-model-free-signed-download-paid-sponsorship-and-support). |
| Can it be distributed today? | Not cleared. FFmpeg is no longer used, and the Apache-2.0 components (the Khronos/Vulkan libraries, MoltenVK, glslang's Apache-2.0 and GPL-3.0 parts, `spirv_reflect` and the `spirv` Rust crate) were removed from the link closure on 2026-10-17; this record has not been reviewed by counsel and the items under [Before any distribution](#before-any-distribution) are open. See [Remaining blockers](#remaining-blockers). |
| Is a Developer ID signed, notarized build available? | No. `scripts/package.py` signs ad hoc, or with a self-signed project certificate for releases. Signing is a platform mechanism, not a license grant. See [Signing and notarization](#signing-and-notarization). |
| Can it be listed on the Mac App Store? | Not as the app is built today, and not without first settling the GPLv2 question. See [Mac App Store](#mac-app-store). |
| Does publishing this source resolve the blockers? | No. Distribution of the combined program is what the licenses govern; posting the repository changes nothing about it. |

## Source license: GPL-2.0-only

This project's original contributions are offered under GNU GPL version 2 only,
except where an existing notice specifies different terms. Third-party code
retains its own licenses; the root license does not replace them. The root
[`LICENSE`](LICENSE) is a verbatim copy of `upstream/renderer/LICENSE`, supplied
so source recipients receive the applicable GPLv2 text.

Why version 2 only: the vendored renderer declares `license = "GPL-2.0-only"`
in its `Cargo.toml`
(https://github.com/bigsaltyfishes/wallpaper-engine-for-macos/blob/main/Cargo.toml),
and the application shell in `App/` is a derived work of that renderer's
`app/WallpaperEngine` sources. GPLv2-only code cannot be relicensed by anyone
but its copyright holders, and the "or any later version" option is one the
upstream authors did not grant
(https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility). This project
therefore inherits GPL-2.0-only for the whole program and applies it to its own
contributions so that the whole is under one license.

What the root `LICENSE` does and does not do:

- It states the terms under which this project's own code (`App/`, `Extension/`,
  `Shared/`, `Renderer/`, `Tests/`, `scripts/`, `project.yml`) is
  offered, and it is the same license the vendored GPL code is already under.
- It does not transfer, merge or relicense anyone's copyright. The
  bigsaltyfishes projects, the mediaremote-adapter authors,
  Phosphene and every other holder named in `upstream/provenance.json`
  and in the notices under `upstream/` keep their copyright and their own
  license terms. Third-party notices are retained where they were found and are
  bundled by `scripts/package.py` (see [Notice payload](#notice-payload)).
- It is not a grant from third parties: where a third party's license is
  incompatible with GPLv2, the presence of this file resolves nothing.

The derived application shell and independently implemented extension and
Workshop browser are recorded in `upstream/provenance.json` under
`applicationShell`, `lockScreenExtension` and `workshopBrowser` as GPL-2.0-only.
The browser is independently implemented; no code from the GPLv3 Unayung/wallpaper-engine-mac project
(https://github.com/Unayung/wallpaper-engine-mac/blob/main/LICENSE) was
copied, translated or adapted, because GPLv2-only and GPLv3 code cannot be
combined into one distributed program
(https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility).

## Supporter model: free signed download, paid sponsorship and support

The website (https://www.wallpapermachine.app) offers WallpaperMachine in two
tiers. Neither changes the license of the software, and no copy of the software
is sold:

1. **Free.** A signed, ready-to-run download, built by this project from a
   tagged revision, signed with this project's Apple Developer ID and notarized
   (once that is implemented; see
   [Signing and notarization](#signing-and-notarization)), or the complete
   source in this repository to build yourself.
2. **Supporter.** A one-time purchase through Paddle.com, the website's
   reseller and Merchant of Record, that buys two things and no software:
   - a **sponsor place**: a name and picture on the website's sponsor wall
     (https://www.wallpapermachine.app/#sponsors) and in the
     [README's sponsor list](README.md#thank-you-to-every-supporter), shown
     only if the Supporter turns it on;
   - **priority support**: wallpaper-compatibility questions and feature
     requests, asked on the website's supporter forum, answered ahead of
     general requests.

The website's terms (https://www.wallpapermachine.app/terms/) state that the
license published in this repository, not those terms, governs the source
code, the signed download and anything built from the source. Its refund
policy (https://www.wallpapermachine.app/refunds/) ends only the sponsor place
and priority support; the download stays free and building from source is
unaffected.

What the GPL permits and requires here, from the license text and the FSF's
own answers:

- Distributing copies gratis and charging for them are both allowed
  (https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowMoney,
  https://www.gnu.org/philosophy/selling.html). Activities other than copying,
  distribution and modification are outside the license (GPLv2 section 0), so
  support and a sponsor listing are services the GPL does not regulate; GPLv2
  section 1 expressly allows offering warranty protection for a fee.
- When a binary is offered for download, offering equivalent access to copy
  the corresponding source from the same place counts as distributing the
  source (GPLv2 section 3;
  https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowDownloadFee).
- No further restrictions may be imposed on recipients' exercise of the rights
  the GPL grants (GPLv2 section 6). That covers the terms of every channel a
  copy is distributed through, an app store's as much as this project's own
  (https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement).
- Requiring everyone who obtains a copy to pay this project, or to notify it,
  is not allowed (https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowRequireFee).
- Anyone may sell copies, modified or not, but only under the GPL: recipients
  must receive the source and the same rights
  (https://www.gnu.org/licenses/gpl-faq.html#GPLCommercially).

The policy that follows from that:

- **The software is never the product.** The download is free and the source
  is here. Nothing in the app checks for, unlocks or changes with a Supporter
  purchase: there is no license key, no Supporter build and no feature gate.
- **Recipients keep every GPL right.** Anyone who receives the signed download
  may run it, study and modify its source, redistribute it, and sell copies
  themselves, gratis or for any price, under GPLv2. No further restriction is
  imposed (GPLv2 section 6). Supporters receive exactly the license everyone
  else does, and a refund takes none of it back.
- **No restrictive EULA.** The signed download ships with the GPLv2 text and
  the third-party notices and with no additional end-user agreement. There is
  no anti-redistribution clause, no reverse-engineering prohibition, no
  per-seat or per-device term, and no claim of ownership over third-party
  code (terms of that kind are what the GPL forbids). The website's account and checkout terms cover the Supporter
  purchase only.
- **Corresponding source travels with every binary.** Each signed download is
  produced from a Git tag `vx.y.z` ([docs/release.md](docs/release.md)). The
  complete corresponding source for that exact binary—including this repository,
  vendored code, all covered linked dependencies, modifications, `project.yml`,
  build/install scripts—is offered alongside the
  download with equivalent access and no fee (GPLv2 section 3(a) and its
  download provision). Mirror the exact dependency source, not merely links to
  third-party servers. A future section 3(b) written-offer route would instead
  require an offer valid for at least three years to any third party, subject to
  its source-distribution cost limit; it is not the selected route.
  GPLv2 expressly includes scripts controlling compilation and installation.
- **Sponsorship and support are services, not license conditions.** The
  sponsor place is a listing and priority support is time and attention. The
  software works identically with or without them.
- **Warranty.** The GPLv2 disclaimer (sections 11 and 12) applies unless this
  project states otherwise in writing. GPLv2 section 1 allows warranty
  protection to be offered for a fee; if a support tier does so, that is a
  written commitment of this project alone and binds no upstream author.

The Supporter model is distinct from release readiness: it describes how the
signed download would be offered once distribution is lawful. Until the
blockers below are resolved, there is no signed download to offer. The
Supporter purchase sells no software and does not change that.

### Mac App Store

The website shows a Mac App Store listing as coming soon. That channel has two
open questions of its own, independent of the license-compatibility items:

- **License.** In 2010 the FSF found that the App Store Terms of Service's
  Usage Rules restrict how recipients may use and distribute a program, which
  GPLv2 section 6 forbids, and Apple removed GNU Go rather than change them
  (https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement).
  This project has not reviewed Apple's current terms against section 6.
  Unless such a review shows they add no further restriction, a listing needs
  an additional permission from the copyright holders of the GPL-2.0-only
  code, the upstream renderer's included. This project has none.
- **App Review.** Apple's App Review Guidelines
  (https://developer.apple.com/app-store/review/guidelines/) require Mac App
  Store apps to be sandboxed (2.4.5(i)), not to download additional code
  (2.4.5(iv)), to take updates only through the Mac App Store (2.4.5(vii)) and
  to use public APIs only (2.5.1). The app is not sandboxed (only its
  lock-screen extension is), downloads SteamCMD at runtime, updates itself
  from GitHub Releases, and uses private interfaces: CoreGraphics and
  HIServices symbols for per-Space desktop pictures, MediaRemote, and the
  `WallpaperExtensionKit` ABI.

## Signing and notarization

Not implemented. `scripts/package.py` signs every bundled dylib, each extension
and the app ad hoc (`codesign --sign -`) by default; release builds sign them with
a self-signed project certificate instead
([docs/build.md](docs/build.md#release-signing)), only so the designated
requirement, and with it macOS privacy permissions, survives in-app updates. Both
let the bundle be checked with `codesign --verify --deep --strict`. No Developer
ID certificate is used and no notarization request is submitted.
Implementing them is engineering work that comes after distribution is cleared.

A signature can verify bundle integrity; Developer ID additionally authenticates
the developer through Apple's certificate chain. Neither an ad-hoc signature nor
the self-signed certificate authenticates a developer identity. Neither signing
nor notarization grants third-party copyright permissions or establishes license
compatibility.

## Components and their licenses

Checked 2026-09-21 against the Homebrew formulae installed on the development
machine, the vendored license files, and the dynamic link closure reported by
`otool -L` on a built `WallpaperMachine` binary. Versions are the installed
ones on that date, not pins. The Rust crates were checked 2026-10-17;
see [Rust crates](#rust-crates) for how.

| Component | Where | License | GPL-2.0-only combination |
|---|---|---|---|
| Renderer (`wallpaper-core`, `wallpaper-bridge`) | `upstream/renderer`, revision in `provenance.json` | GPL-2.0-only | Same license |
| Shader layer (`wm-shader`: Wallpaper Engine shader text to Metal Shading Language, reflection, the C ABI the scene engine calls) | `Renderer/Shader` (a Rust workspace of its own, `Renderer/Cargo.toml`), linked into `libwallpaper_bridge.a` | GPL-2.0-only (this project; clean-room, see the [implementation record](#implementation-record)) | Same license |
| Scene engine (open-wallpaper-engine) | `upstream/renderer/external/open-wallpaper-engine` | GPL-2.0-only (vendored under the renderer) | Same license |
| Application shell, extension, Workshop browser, control panel, scripts, new renderer code | `App/`, `Extension/`, `Shared/`, `Renderer/`, `scripts/` | GPL-2.0-only (this project) | Same license |
| Phosphene ABI reference | notice in `Extension/Phosphene-LICENSE.txt` | MIT | Compatible |
| ungive/mediaremote-adapter | `upstream/mediaremote-adapter` | BSD-3-Clause | Compatible; embedded as an unlinked framework |
| miniaudio | `upstream/renderer/external/open-wallpaper-engine/third_party/miniaudio` | Public domain or MIT-0 (choice) | Compatible |
| stb_image | `upstream/renderer/external/open-wallpaper-engine/third_party/stb_image.h`, v2.26 | Public domain or MIT, licensee's choice (end of the header) | Compatible |
| stb_vorbis | `upstream/renderer/external/open-wallpaper-engine/third_party/stb_vorbis`, v1.22 (nothings/stb commit `1ee679ca`), unchanged, linked statically (`stb_vorbis`) | Public domain (Unlicense) or MIT, licensee's choice (`LICENSE` there and the end of `stb_vorbis.c`) | Compatible |
| nlohmann-json, argparse | Homebrew, header-only | MIT | Compatible |
| quickjs-ng | Homebrew `quickjs-ng` 0.16.2, `libqjs` in the verified Debug dependency closure | MIT | Compatible |
| lz4 | Homebrew `lz4` 1.10.0 | BSD-2-Clause | Compatible |
| FreeType | Homebrew `freetype` 2.14.3 | FTL or GPL-2.0-or-later, licensee's choice (`LICENSE.TXT` in the keg) | Compatible under the GPLv2 option; the FTL option is not GPLv2-compatible and is not the one used |
| libpng | Homebrew `libpng` 1.6.58 (FreeType dependency) | libpng-2.0 | Compatible |
| naga 29.0.3 | Rust crate, a patched copy vendored in `upstream/naga` (`upstream/naga/PATCHES.md`): the shader translator and validator the `wm-shader` crate (`Renderer/Shader`) uses for every shader; built with `glsl-in` and `msl-out` only | MIT OR Apache-2.0, used under MIT | Compatible under the MIT terms; the patch makes Apache-2.0 `codespan-reporting` an optional dependency `wm-shader` does not enable, so it is no longer linked, and dropping `spv-out` removed the Apache-2.0 `spirv` crate |
| uniffi 0.28.3 (`uniffi`, `uniffi_core`, `uniffi_bindgen`, `uniffi_meta`, `uniffi_udl`, `uniffi_testing`), option-ext 0.2.0 | Rust crates: the Swift bridge, and `dirs` | MPL-2.0 | Compatible through MPL-2.0 section 3.3, which names GPL-2.0 as a Secondary License; none of their source files carries the "Incompatible With Secondary Licenses" notice |
| The other 140 linked Rust crates | `upstream/renderer/Cargo.lock` | 136 offer MIT, alone or as a choice; the rest are Zlib (foldhash), BSD-3-Clause (pp-rs) or BSD-3-Clause OR Apache-2.0 (moxcms, pxfm) | Compatible under the MIT, Zlib or BSD-3-Clause terms |
| Valve SteamCMD | installed at runtime into the app's support directory, never bundled | Valve's terms | Outside the GPL entirely; see [Rights outside software licenses](#rights-outside-software-licenses) |

"Compatible" in this table means compatible with GPLv2 according to the FSF's
license list (https://www.gnu.org/licenses/license-list.html) or the license's
own text; it is not an audit of every file.

Removed on 2026-10-17, each from the source tree, the build and the link closure (the
commits are in this repository's history, and `upstream/provenance.json` records them):

| Component | License | Removed by |
|---|---|---|
| `spirv_reflect` (vendored, `spirv-reflect-static`) | Apache-2.0 | `19aeb2e8` |
| Vulkan Memory Allocator (`vk_mem_alloc.h`, vendored) | MIT | `19aeb2e8` |
| The Vulkan renderer, its wrapper and swapchain code, the SPIR-V shader target | project code | `19aeb2e8` |
| `spirv` 0.4.0, Rust crate (naga's `spv-out` feature) | Apache-2.0 | `19aeb2e8` |
| glslang (`libglslang`, `libSPIRV`, `libglslang-default-resource-limits`) | BSD-3-Clause, BSD-2-Clause, MIT, Apache-2.0 for parts, GPL-3.0-or-later with the Bison exception for the parser skeleton | `19aeb2e8` (linking), `a289d5e9` (Homebrew dependency) |
| SPIRV-Tools (`libSPIRV-Tools`, `libSPIRV-Tools-opt`) | Apache-2.0 | `19aeb2e8` (linking), `a289d5e9` (Homebrew dependency) |
| Vulkan loader (`libvulkan`) | Apache-2.0 | `19aeb2e8` (linking), `a289d5e9` (Homebrew dependency) |
| MoltenVK (`libMoltenVK`, the Vulkan ICD) and `MoltenVK_icd.json` | Apache-2.0 | `19aeb2e8` (use), `a289d5e9` (bundling) |
| vulkan-headers, spirv-headers, shaderc (Homebrew, build-time) | Apache-2.0 / MIT | `a289d5e9` |
| FFmpeg 8.1.2 (`libavformat`, `libavcodec`, `libavutil`, `libswresample`, built by `Formula/mwe-ffmpeg.rb`; the formula and `scripts/install_ffmpeg.py` are deleted) | LGPL-2.1-or-later as configured | `3c55d52b` (audio decoder), `f0e3b270` (video backend, engine link), `d2c891aa` (Rust decoder, link lines), `b6ba0c32` (app link flags, formula, installer, preflight, CI cache) |
| dav1d (Homebrew, FFmpeg's AV1 decoder) | BSD-2-Clause | `b6ba0c32` |
| `ffmpeg-next`, `ffmpeg-sys-next` 8.1.0, Rust crates (the FFmpeg bindings in `wallpaper-core`) | WTFPL | `d2c891aa` |
| `hermit-abi`, `num_cpus`, `pkg-config`, `vcpkg`, Rust crates (build dependencies only `ffmpeg-sys-next` pulled in) | MIT OR Apache-2.0 (`vcpkg`: MIT/Apache-2.0) | `d2c891aa` |

### Rust crates

Checked 2026-10-17 (and again after the FFmpeg crates left, `d2c891aa`) against `upstream/renderer/Cargo.lock` with `cargo tree
--offline --workspace -e normal,no-proc-macro --target aarch64-apple-darwin`.
That resolves features the way `scripts/build.py`'s `cargo build --workspace
--release` does. Each crate's license is the one its manifest declares; no
crate was reviewed file by file. The result is 148 third-party crates (naga counted among them, as the
vendored copy in `upstream/naga`), all compiled into `libwallpaper_bridge.a`,
which the app links (`-lwallpaper_bridge` in `project.yml`).

Native Metal is the only scene renderer ([docs/features/scene-rendering.md](docs/features/scene-rendering.md#scene-renderer)).
The Compatibility renderer (Vulkan through MoltenVK) and its SPIR-V shader target are
deleted: the `spirv` crate (Apache-2.0) left the closure with naga's `spv-out` feature
(`upstream/renderer/crates/shader/Cargo.toml` builds naga with `glsl-in` and `msl-out`),
and `codespan-reporting` left earlier through the vendored naga's optional dependency.

A Release executable built 2026-10-16, before codespan-reporting and spirv left the
closure, contained code from both, among others (by their names in its symbol table). That
describes one build and clears nothing by itself; the closure check below is what
reports the current state.

uniffi's `cli` feature is enabled in `wallpaper-bridge`'s normal dependencies
because the package's `uniffi-bindgen` binary needs it. As a result
`uniffi_bindgen` (MPL-2.0) is compiled into the app executable as well.

Not covered: build-dependencies and proc-macros, which run inside the compiler
and are not linked; and the contents
of each crate beyond its declared license.

## FFmpeg

FFmpeg is no longer used. It was removed on 2026-10-17 (`3c55d52b`, `f0e3b270`,
`d2c891aa`, `b6ba0c32`; [Components and their licenses](#components-and-their-licenses)
lists them), so the app links, bundles and caches no `libav*`, `libsw*` or
`libpostproc` library, no FFmpeg bindings and no dav1d, and the repository has
no FFmpeg formula or installer. Checked on the Release
app built from `b6ba0c32` has no `libav*` among its Mach-O dependencies (`otool
-L` on the app executable and on the lock-screen extension lists only
`liblz4`, `libfreetype` and `libqjs` outside Apple's libraries, and
`Contents/Frameworks` of a built bundle holds only the unlinked
`MediaRemoteAdapter.framework` until packaging), and no `_av_*`, `_avcodec_*`,
`_avformat_*`, `_sws_*` or `_swr_*` symbol is undefined in it.

What replaced it, all written for this project or taken from the system:

- Video: the project's own MP4/QuickTime and WebM/Matroska readers
  (`Renderer/Media`) feed VideoToolbox, which decodes H.264, HEVC, VP9 and, where
  the Mac has the hardware, AV1. The app's own players (AVFoundation, and the WebM
  player) play a plain video wallpaper and the lock screen; the scene engine
  plays a scene's video textures with the same readers and decoder.
- Sound: AudioToolbox decodes MP3, AAC, FLAC, WAV and the rest the system reads;
  Ogg Vorbis is the vendored, public-domain `stb_vorbis`; remixing, resampling and
  looping are `Renderer/Sound`.

What stopped working with it: VP8, AV1 on a Mac without an AV1 hardware decoder,
4:2:2 video, a fragmented MP4 and a container other than the four above. Each now
fails with a reason that starts "format not supported: " where the format is the
cause, and the wallpaper keeps its last picture.

Before this change the project had already replaced Homebrew's `ffmpeg@8`
(configured with `--enable-gpl --enable-version3 --enable-openssl`, so
GPL-3.0-or-later with Apache-2.0 OpenSSL, neither of which can be combined with
this GPL-2.0-only program) by an LGPL-2.1-or-later build of the same release. Neither
is part of the product now.

FFmpeg's command-line tools are not part of the repository, the build or any
distribution. A developer may have `ffmpeg` or `ffprobe` installed: the test fixtures
under `Tests/Unit/NativeVideo` and `Renderer/Sound/tests` record the commands that
generated them (embedded as bytes, so no test needs the tool), and the container
readers' optional corpus checks compare with `ffprobe` when it is present
(`docs/container-readers.md`). That is use of a tool by a developer, not a
dependency of the program.

The earlier note about patented codecs (that FFmpeg's page says companies
making money from products using them have been approached by patent licensors) was
recorded while FFmpeg's software codecs were bundled. The program now carries no
codec implementation of its own beyond `stb_vorbis` (Vorbis) and delegates the rest
to Apple's VideoToolbox and AudioToolbox. That is a statement of what is bundled, not
a legal conclusion: Apple's terms for those frameworks and the business risk of a
signed download beside a paid Supporter purchase have not been reviewed by counsel.

## Remaining blockers

The FSF's position is that the Apache License 2.0 is not compatible with GPL
version 2 because of its patent-termination and indemnification terms
(https://www.gnu.org/licenses/license-list.html#apache2), and this project's policy
table rejects the GPL-3.0 family for the same GPL-2.0-only combination.

**State on 2026-10-17.** `python3 scripts/check_licenses.py --enforce`, run on the tree
after the FFmpeg removal (`b6ba0c32`) and on a Release app built from it, reports 177
components (3 Mach-O roots, 5 third-party libraries walked from them, 24 compiled-in or
statically linked inventory entries and 151 third-party Rust crates) with 0 Apache-2.0, 0
GPL-3.0 family, 0 unknown and 0 not named in this file; with `--skip-app` it reports 175
with the same zeros. The third-party libraries the app loads are `lz4`,
`freetype` (with its `libpng`), `quickjs-ng` and the unlinked `MediaRemoteAdapter`
framework; no `libav*` library is among them ([FFmpeg](#ffmpeg)). The
earlier run, after the Vulkan deletion and before the FFmpeg removal, reported 181
(178 with `--skip-app`). The Apache-2.0 and GPL-3.0 parts that
used to be loaded into, or compiled into, the same process as the GPL-2.0-only renderer
are gone (see the table of removed components above): `libvulkan` and `libMoltenVK`,
`libSPIRV-Tools` and `libSPIRV-Tools-opt`, glslang (its Apache-2.0 portion and its
GPL-3.0-or-later parser skeleton), the vendored `spirv_reflect` and the Rust crate
`spirv`. Neither the app nor the lock-screen extension executable of that build links or
loads Vulkan, glslang, SPIRV or MoltenVK libraries (`otool -L`), and the bundle carries no
`MoltenVK_icd.json`.

What this does not establish: it counts declared licenses, not files (the Rust crates
were audited by declared license only, and the vendored sources by their notices); it is
not a legal opinion, and none has been obtained. FFmpeg, the only LGPL component the table
above listed, is no longer linked. No grant or permission from any copyright holder was requested or received,
and none is described as existing.

Should a component under Apache-2.0 or the GPL-3.0 family enter the closure again,
the check reports it and no binary may be distributed, sold or given away until it is
resolved. Resolution means one of:

1. **Replace** the component with one under a GPLv2-compatible license or with
   code written for this project, and remove the Apache-2.0 code from the link
   closure. For a Rust crate it means dropping the feature or dependency that
   pulls it in, or replacing or patching the crate that needs it: the vendored
   naga builds without `codespan-reporting`, and without `spv-out`, so without
   `spirv`.
2. **Obtain compatible license grants** covering the Apache-2.0 code, or obtain
   a sufficient linking exception or GPLv3-compatible relicense from the
   copyright holders of the GPLv2-only code. A generic endorsement is not enough.
   Grants must come from the actual holders of the code involved—for the renderer that means
   every contributor whose code is in the combined work, not only the current
   repository maintainer; for the Khronos projects that means their
   contributors, not a downstream packager - and has to be kept in writing.
3. **A qualified legal opinion** that a particular boundary (for example the
   loader/ICD interface) is an aggregation rather than a combined work. The
   FSF's guidance is that this depends on how the pieces communicate, not on
   the process or container boundary
   (https://www.gnu.org/licenses/gpl-faq.html#MereAggregation); this project
   has no such opinion and does not rely on one.

Nothing here is resolved by publishing the source. The GPL does not require a
modified version to be published at all
(https://www.gnu.org/licenses/gpl-faq.html#GPLRequireSourcePostedPublic), and
publishing one does not make its combination with incompatible code lawful to
distribute. Private use and private builds are unaffected
(https://www.gnu.org/licenses/gpl-faq.html#WhatDoesCompatMean).

Also still open: the Rust crates beyond their declared licenses, including
build-dependencies and proc-macros.

## Rights outside software licenses

None of the licenses above authorize anything on this list; each is a separate
question for any distribution and for the Supporter model:

- **Valve software.** SteamCMD is downloaded by the user at runtime into the
  app's support directory and is never bundled or redistributed. Use of
  Steam's interfaces is subject to Valve's terms, which this project has not
  reviewed with counsel.
- **Wallpaper Engine assets.** Scene wallpapers need shared resources from a
  purchased Wallpaper Engine installation. They are proprietary, are not
  bundled, and the app does not distribute them.
- **Workshop content.** Wallpapers belong to their creators and are downloaded
  by the user with the user's own Steam account. The app does not host or
  redistribute them.
- **Product naming.** The application is named WallpaperMachine, but the
  website and the README lead with the third-party product name "Wallpaper
  Engine" ("Wallpaper Engine. Meet your Mac."). Settings -> About, the website
  and the README state that the project is not affiliated with Wallpaper
  Engine or Valve. Whether that use of the name can accompany a paid Supporter
  offering is a trademark question this project has not had reviewed.
- **Private Apple API.** The lock-screen extension uses the private
  `WallpaperExtensionKit` ABI, which is not an Apple-supported public API.
  This is a platform-policy and support risk, not a license question, and it
  is unaffected by anything in this document.

## Tooling that enforces this record

As implemented by `scripts/package.py` and `.github/workflows/build.yml`
([docs/build.md](docs/build.md), [docs/release.md](docs/release.md)):

- `scripts/package.py` runs a preflight before touching the bundle. It refuses
  when any notice it must bundle is missing, or any Homebrew keg it bundles ships
  no license file. `--check` runs only the preflight. (It used to refuse FFmpeg
  libraries whose embedded configuration was not an LGPL build; no FFmpeg library
  is linked now.)
- `.github/workflows/build.yml` used to fail at its first step, citing this
  file. The maintainer removed that step for 1.0.0 (2026-09-26), so CI now
  publishes release disk images while the items under [Before any distribution](#before-any-distribution) are open.
- Local disk images produced by `scripts/package.py` are labelled as not cleared
  for distribution.
- `python3 scripts/check_licenses.py` lists the license of every Mach-O
  dependency of the built app (`otool -L`, walked recursively from the main
  executable, the extension and `Contents/Frameworks`), of the third-party code compiled or statically linked into the
  renderer (a source inventory: `crates/core/build.rs`, the scene engine's CMake
  `find_package` targets and `third_party/`, against a hand-kept license table
  in the script) and of every linked Rust crate (`cargo tree`, the same set as
  [Rust crates](#rust-crates); a vendored path crate under `upstream/` outside
  the renderer workspace, naga, counts as third party with the license its
  `Cargo.toml` declares). It classifies SPDX expressions against one
  policy table (today GPL-2.0-only: Apache-2.0, the GPL-3.0 family and unknown
  licenses fail), prints the Apache-2.0 components and any failing component
  this file does not name. It is report-only by default; `--enforce` exits 1.
  It needs a built app, Homebrew and Cargo, so the routine gate does not run it.

The packaging checks catch a missing notice. An Apache-2.0 component is a matter of
what is linked, not of a string in one library; `scripts/check_licenses.py` reports
it from the link closure, in report-only mode unless `--enforce` is given. Its
license table carries no entry for FFmpeg or dav1d, so a `libav*` library or CMake
package that returns is reported as unknown.

### Notice payload

`scripts/package.py` writes the following into the app bundle:

- `Contents/Resources/WallpaperMachine-LICENSE.txt`: the root `LICENSE`;
- `Contents/Resources/LICENSING.md`: this file;
- `Contents/Resources/Renderer-LICENSE.txt`: `upstream/renderer/LICENSE`;
- `Contents/Resources/provenance.json`: `upstream/provenance.json`;
- `Contents/Resources/Licenses/<formula>-<version>/`: every `LICENSE*`,
  `COPYING*`, `COPYRIGHT*` and `NOTICE*` file of each Homebrew keg in the link
  closure;
- `Contents/Resources/Licenses/renderer-third-party/{miniaudio,stb_vorbis}/LICENSE`.

Xcode separately bundles `Contents/Resources/LICENSE` (mediaremote-adapter's
BSD-3-Clause notice) and the extension's `Phosphene-LICENSE.txt`.

No notice from the [Rust crates](#rust-crates) is bundled yet, although the
MIT, ISC and BSD-3-Clause terms of the linked crates ask for their notices to
go with binary copies.

## Implementation record

The native application is named **WallpaperMachine**; its bundle identifier
prefix is `app.wallpapermachine`.

- Renderer source is in `upstream/renderer`, based on revision
  `8c19c002ff37930c68117dd591dfe3f44792e25e`, modified as recorded in
  `upstream/provenance.json`.
- The application shell in `App/` is a derived work of that renderer revision's
  `app/WallpaperEngine` sources, relocated out of `upstream/renderer` so the
  sources this project actively develops are not mixed into vendored
  third-party code. The relocation moves files only: GPL-2.0-only terms and the
  upstream copyright notices continue to apply.
- The native lock-screen extension is in `Extension/`, with
  `Extension/Phosphene-LICENSE.txt` carrying the third-party notice for the
  MIT-licensed [Phosphene](https://github.com/kageroumado/phosphene/tree/8b5bd57c1450eda74cf2ec6ceaae2e586cfdfcd6)
  protocol/Codable layout used as an ABI reference.
- The Workshop browser and downloader were independently implemented for this
  client.
- The container readers in `Renderer/Media` were written for this project from the public
  ISO/IEC 14496-12/-15, Matroska element and RFC 8794 EBML specifications and the VP9 and
  AV1 bitstream specifications. Their Apple layer (`Renderer/Media/Apple`, the codec format
  descriptions, the VideoToolbox decoder wrapper and `WebMReader`, the Objective-C face of the Matroska reader that the app's WebM player and the lock-screen extension use) and the scene engine's native video
  backend (`Video/NativeVideoBackend.cpp` and
  `Video/VideoTextureSourceFactory.cpp`) were written from Apple's public VideoToolbox, Core
  Media and Core Video headers and documentation. `Video/ClockedVideoSource.cpp` is not new
  code: it is the clock, queue, seek and promotion logic of the engine's existing
  open-wallpaper-engine `FfmpegVideoTextureSource.cpp` (GPL-2.0), moved into its own file and
  left otherwise as it was. No code from FFmpeg, libav, libwebm, libmatroska, libvpx, mp4v2,
  Bento4, GPAC or any other implementation was copied into the new code. FFmpeg was removed
  on 2026-10-17 ([FFmpeg](#ffmpeg)): the native backend is the only video decoder.
- The sound path in `Renderer/Sound` (channel remix, resampler, loop pipeline the AudioToolbox and Ogg Vorbis decoder adapters, and `Renderer/Sound/Matroska`, which decodes the audio of a WebM or Matroska file: Opus, AAC and MP3 packets through an AudioToolbox AudioConverter, Vorbis packets re-framed as an in-memory Ogg stream for stb_vorbis, written from the Matroska, RFC 6716, RFC 7845 and RFC 3533 specifications and Apple's documentation) was written for this project from the documented behaviour of a conventional downmix, the mathematics of windowed-sinc resampling and Apple's AudioToolbox documentation. No code from FFmpeg, libswresample, libvorbis, opus or any other implementation was copied; Ogg Vorbis decoding is the public-domain stb_vorbis, vendored unchanged. FFmpeg no longer decodes scene sounds, and no longer decodes the audio of a plain video wallpaper on the desktop, where the app's own players play it (AVFoundation, or the WebM player over the sound decoders above); the scene engine no longer builds a plain-video scene at all (removed 2026-10-17), so it decodes no plain video's audio anywhere.
- The still preview in `Renderer/Surface` (`wmSurface`: the rule that picks a project's preview file inside the project's own folder, and an ImageIO decoder that lays the picture over a surface's layer as a Core Animation sublayer) was written for this project from Apple's ImageIO and Core Animation documentation. No code from any other implementation was copied. It is linked into the app and, through the scene engine, into the lock-screen extension, and it adds no third-party dependency.
- The shader layer in `Renderer/Shader` (the Rust crate `wm-shader`: the preprocessor, the
  converter from Wallpaper Engine's HLSL-flavoured GLSL to GLSL 450, the legalizer that lays out
  resources and interfaces for naga, the Metal back end and reflection, and the C ABI the scene
  engine calls) replaced the shader crate that came with the imported renderer, in the commit
  titled "replace the imported shader crate with the clean-room wm-shader" (2026-10-17). It was written under a clean-room protocol: one session studied the
  retired crate and wrote plain-prose specifications (contract, preprocessor, dialect and types,
  legalization and structure, pipeline and back end, and a first amendment list); separate sessions
  that never opened the retired crate, its history or the study notes wrote the code and its tests
  from those specifications, naga's public documentation and Apple's Metal documentation; a
  verification session compared the two as black boxes; only the swap session, which deleted the
  retired crate, read both. The specification files and their SHA-256 are in
  `upstream/provenance.json` (`renderer.shaderCrateReplacement`). The retired crate's source is
  gone from the tree (`upstream/renderer/crates/shader`); it remains in Git history, under
  GPL-2.0-only. The only third-party dependency of the new crate is the vendored naga; the crates
  the retired one used for tokens, string storage and static registration (`logos`, `smol_str`,
  `linkme`) are no longer linked.
- System now-playing metadata uses [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
  at revision `73f14ab1568371e6e3c44063f21c34c5e2712c4d`, BSD-3-Clause, vendored
  under `upstream/mediaremote-adapter` with the `src/adapter/stream.m` changes
  recorded in `upstream/provenance.json`, and built as an embedded, unlinked
  framework.
- The shader translator [naga](https://github.com/gfx-rs/wgpu) 29.0.3 is vendored
  under `upstream/naga` (its `LICENSE.MIT` and `LICENSE.APACHE` ship with it; this
  project uses it under the MIT option) with the patch listed in
  `upstream/naga/PATCHES.md`, recorded in `upstream/provenance.json`.
- The control panel's icons are SF Symbols, drawn by macOS at run time; no
  icon artwork is copied into the app or the repository, so no icon notice
  ships.

## Before any distribution

- Run `python3 scripts/check_licenses.py --enforce` on the Release app that would
  be distributed and record the outcome here with the evidence; resolve anything
  it reports by replacement or by written permission from the actual copyright
  holders.
- Review the Rust crates beyond their declared licenses.
- Bundle the notices of the Rust crates the app links.
- Implement Developer ID signing and notarization in the release pipeline, and
  remove the unconditional failure from `.github/workflows/build.yml` only
  after the review above is recorded as done.
- Mirror the corresponding source (the repository at the tag) at the place the
  signed download is offered.
- Review Valve's terms and the product-name question with counsel before the
  first public download or Supporter sale.
- Before any Mac App Store listing, settle both questions under
  [Mac App Store](#mac-app-store).
- Keep every third-party notice intact and identify modifications as GPLv2
  section 2(a) requires.

## Local build and use

This build targets Apple Silicon and macOS 15 or later, and requires Xcode and
Homebrew. Packaged renderer libraries are bundled into the app for local use
only and are not cleared for distribution.

- Prerequisites, dependencies and commands: [docs/build.md](docs/build.md).
- Steam sign-in, download and scene-asset behavior:
  [docs/features/workshop-downloads.md](docs/features/workshop-downloads.md).

Dated verification history: [docs/testing/verification-log.md](docs/testing/verification-log.md).

## References

- GNU GPL version 2 text: https://www.gnu.org/licenses/old-licenses/gpl-2.0.html
- GPL FAQ, selling copies: https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowMoney
- GPL FAQ, download fees and equivalent source access: https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowDownloadFee
- GPL FAQ, no fee may be required of others' recipients: https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowRequireFee
- GPL FAQ, selling modified versions commercially: https://www.gnu.org/licenses/gpl-faq.html#GPLCommercially
- GPL FAQ, GPLv2/GPLv3 incompatibility: https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility
- GPL FAQ, what "compatible" means: https://www.gnu.org/licenses/gpl-faq.html#WhatDoesCompatMean
- GPL FAQ, no obligation to publish private modifications: https://www.gnu.org/licenses/gpl-faq.html#GPLRequireSourcePostedPublic
- GPL FAQ, aggregation versus combined work: https://www.gnu.org/licenses/gpl-faq.html#MereAggregation
- FSF license list, Apache 2.0 incompatible with GPLv2: https://www.gnu.org/licenses/license-list.html#apache2
- FSF, selling free software: https://www.gnu.org/philosophy/selling.html
- Renderer license file: https://github.com/bigsaltyfishes/wallpaper-engine-for-macos/blob/main/LICENSE
- FSF, App Store terms and GPL section 6: https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement
- Apple App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- WallpaperMachine terms of service (Supporter purchase, Paddle): https://www.wallpapermachine.app/terms/
- WallpaperMachine refund policy: https://www.wallpapermachine.app/refunds/

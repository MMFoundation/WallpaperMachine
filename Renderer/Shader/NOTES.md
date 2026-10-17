# Shader crate notes

This project's own code, written from the clean-room specification (no upstream
code consulted). The spec is `specs/shader/` of the own-code plan; this file
records what the spec leaves open and the choice made, plus dependency and
toolchain facts. Keep it current as later steps land.

## Layout

`Renderer/Cargo.toml` is the workspace (resolver 2, edition 2024, GPL-2.0-only
until the relicensing phase). `Renderer/Shader` is the crate `wm-shader`
(`rlib` + `staticlib`; the non-default `ffi` feature is declared and reserved
for the C ABI, which a later step adds).

## Dependencies

- `naga` 29.0.3 by path (`../upstream/naga` from `Renderer/`), features
  `glsl-in` and `msl-out` only (MIT OR Apache-2.0). Not used by step 1 code yet
  (it is the compiler the pipeline will call); it is declared now so the
  workspace resolves and builds with it. `identity::NAGA_VERSION` is checked
  against the vendored manifest by a test.
- Nothing else. The request reader and the response writer use the crate's own
  small JSON module (`json.rs`; strict RFC 8259, depth limited to 128), cache
  keys use an own SHA-256 (`sha256.rs`, FIPS 180-4, test vectors), errors
  implement `Display`/`Error` by hand. No `thiserror`, no `serde`.

## Toolchain

`rust-toolchain.toml` pins `nightly` with the Apple target. The development
machine has Homebrew's stable cargo/rustc 1.98.1 and no rustup, which ignores
the file; the crate uses no nightly feature and builds, tests and passes clippy
(`cargo clippy --all-targets`, warnings denied) on that compiler.

## Spec ambiguities and the choice made

1. **R12 "folded name".** The duplicate-combo text uses the ASCII *lower-case*
   spelling as the folded name and then names both original spellings:
   ``duplicate combo name `transformuv` (given as `TransformUV` and `TRANSFORMUV`)``.
2. **R11, several stage problems.** When more than one thing is wrong the text
   lists all of them joined by `; ` (for example "duplicate vertex stage;
   missing fragment stage"), so a reader looking for either wording finds it.
3. **Error wording classes (Q10).** Problems reading the document (bad JSON,
   wrong types, missing keys, unknown enum spellings, duplicate keys, a slot
   that does not fit a byte, an unknown target) start with
   "json request parse failed". Rule violations of R10 to R14 start with
   "invalid shader request". Non-UTF-8 input says "request is not valid UTF-8".
4. **Duplicate keys.** A *known* key given twice anywhere in the document is a
   parse error ("duplicate key"); `cache_policy` together with
   `cache_strategy` is reported the same way. Unknown keys may repeat, they are
   never read.
5. **Cache policy details.** `mode` is required inside the object. `scene_id`
   is read only for `enabled` (any string, including empty, is accepted) and is
   ignored for `disabled`.
6. **Property numbers.** Stored as `f64`; a JSON number that overflows to
   infinity is a parse error ("out of range"). A `none` property needs no inner
   `value`; the outer `value` object itself is required. Duplicate property names
   are not rejected (the spec does not say), and order is kept.
7. **Texture slot tokens.** Only plain non-negative integer tokens count as a
   slot: `1.0`, `1e1`, `-1` and strings are parse errors ("does not fit in a
   byte"), 256 and up likewise; 32 to 255 are range errors from validation.
8. **JSON BOM.** A byte order mark in the *request document* is rejected (it is
   not JSON). Handling a BOM in *shader source* (edge case 17) is the
   preprocessor's business.
9. **Cache key order and contents (Q8, Q12).** Combos are hashed in sorted
   (name, value) order and texture records in slot order, so reordering them in
   the request does not change the key. Properties keep request order (their
   input is unused today and order could matter to a future reader). Stage
   order is part of the key because output order follows it (R9). The raw source
   text is hashed in addition to the preprocessed text and translated GLSL:
   annotations live in comments the preprocessor drops, yet the metadata depends
   on them (R84 "shader source text").
10. **Digest.** SHA-256 truncated to 128 bits, 32 lower-case hex digits.
11. **Compiler identity.** `wm<revision>-naga-<naga version>-msl<language
    version>-<options>`, currently `wm1-naga-29.0.3-msl2.0-untransformed`
    (letters, digits, `.` and `-` only: safe in a file name, and different from
    the stored upstream identity). `cache_key.rs` carries an append-only golden
    table of program keys per identity (R88): a change to what a key covers
    fails the row of the current identity and forces a deliberate bump and a new row.
12. **R83 (target changes the key).** The target is hashed, but with a single
    accepted target no test can change it; the test belongs with the first
    additional target.
13. **Diagnostics.** The document keeps exactly the five keys of 2.6.4 (no
    severity). Pass names are `Preprocess`, `Parse`, `Legalize`, `Codegen`,
    `GlslParse`, `Validate`, `MslWrite`, `Binding`, `Reflection` (only `Codegen`
    is pinned by the spec; the rest name the steps R71 lists). Failure text
    layout: `error: <message>`, `  --> <origin>:<line>:<column>`, a numbered
    excerpt with one line of context each side (at most five lines of the span),
    carets under a single-line span, and a `= stage: ..., pass: ..., shader: ...`
    line. The origin is `generated/<stage>.glsl` for downstream failures,
    otherwise `<shader name>.vert|.frag`. Blocks of several diagnostics are
    separated by a blank line. Control characters in anything echoed
    (tabs become spaces, the rest `?`) are removed so no terminal escape can
    reach the text (R71); values echoed from a request are cut at 120 characters.
    A span that is outside the text (or inside a multi-byte character) is not
    clamped: the excerpt and the line/column are left out (R73).
14. **Shader name in failure text.** Included for source failures (2.4 allows
    it); request and include failures do not carry it.
15. **Uniform error wording.** `UniformError` text has no prefix so that it
    *begins with* the wording R46, R99 and R100 fix.
16. **Matrix and array sizes (Q17).** Block members report the true std140
    footprint: `mat2` 32, `mat3` 48, `matCxR` is C columns of 16 bytes; array
    strides are the element size rounded up to 16 (so `int[N]` and `ivec3[N]`
    have stride 16, `mat2[N]` 32, `mat3[N]` 48); `float`, `vec2` and `vec3`
    arrays are widened to `vec4` elements (element count 4, stride 16). An array
    count of 0 and a block over 4 GiB are errors. Whether the MSL struct the
    pipeline writes agrees with these offsets is the pipeline's obligation
    (checked when it exists).
17. **Reflection merge.** Vertex inputs are ordered by (location, name) and
    exact duplicates collapse; the R36 index limits are checked inside `merge`.
    Active texture slots are a `BTreeSet<u8>` shared by the metadata and
    reflection documents so they cannot differ in order or duplicates (R52).
18. **Include paths.** Validity is checked on the normalised text: empty, NUL,
    leading `/` (which covers `//` and a backslash UNC prefix), a drive prefix
    (an ASCII letter then `:`), or a `..` component.

## Not in step 1 (planned for later steps)

The C ABI and last-error buffer (R1 to R9, R70 buffer, R89 to R93), include
fetching, preprocessing, the metadata scanner and its value parsing (R53 to
R62, R103, R108 to R110), uniform declaration merging across stages (R46) and
array-bound resolution (R100), resource index allocation (R31 to R35, R102),
the legalizer, GLSL generation, the naga calls and the MSL writer, the NV12
variant (R63 to R69), the MSL/golden checks of R88, and the corpus test.

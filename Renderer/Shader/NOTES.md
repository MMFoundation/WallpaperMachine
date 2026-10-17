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

Modules by spec part. Step 1: `request`, `request_json`, `json`, `names`,
`include` (path rules), `response`, `reflection`, `uniforms`, `binding`,
`diagnostic`, `error`, `cache_key`, `identity`. Step 2 (part B of the spec):
`source` (include providers, `CachingSource`), `preprocess` (`expr`,
`lighting`), `lexer`, `facts` (R43 to R49), `items` (R50 to R55),
`annotation` (JSON reader, R8 text conversion), `metadata` (R62 to R71),
`prepare` (the combo protocol, P1 to P5). `tests/corpus.rs` runs the front end
over the shipped shaders (and over workshop shaders unpacked under
`artifacts/p5/workshop-shaders/<id>/shaders/`, which it skips when absent);
`tests/robustness.rs` feeds it garbled and hostile text.

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


## Step 2 choices (preprocessing, tokens, facts, items, metadata)

Preprocessor and includes:

19. **Block comments (Q3).** As R12 says, the preprocessor is not comment aware:
    a directive on its own line inside `/* ... */` is executed. Metadata is
    unaffected because the lexer drops block comments before annotations are
    looked for.
20. **Continued directives (Q2).** A directive line whose last physical line ends
    in `\` is joined with the next one before it is read. The joined body (a
    continuation replaced by one space) feeds `#if` and `#define`; the output of
    `#define` and unknown directives keeps the original line breaks and the
    backslashes, so the downstream compiler sees the continued definition.
    Diagnostics name the first physical line. Ordinary lines keep R31: only the
    backslash is dropped (blanks before it stay, blanks after it go).
21. **Directive bodies (R14).** A body that starts with `<` but has no `>`
    protects nothing. A quote preceded by a backslash never toggles quoting, in
    or out of a string.
22. **Order of checks.** For `#else` the structure errors (unmatched, duplicate)
    come before the trailing-token error; for `#endif` the trailing-token error
    comes first, so `#endif junk` fails even when it is stray.
23. **Unknown directives in the view.** In the metadata-preserving view an unknown
    directive is kept once, normalised, whether its region is active or not
    (Q1's double emission is dropped); an inactive `#undef` is kept normalised
    and not applied.
24. **Plain numbers (R25).** A fraction needs digits after the dot: `5.` is
    opaque, `.5` is opaque, `+3` is the integer 3. A macro whose text is empty
    after a combo with an empty value is opaque and false.
25. **Chains (R25a).** A link is a macro whose whole text is one other
    identifier. Sixteen links resolve, seventeen fail; a link to a name that is
    not defined, a cycle, and an end text that is neither a plain number nor an
    identifier all give the unsupported-expression error naming the cause.
26. **Combo values with line breaks (Q21).** CR and LF in a combo value become a
    space in the definition line and in the environment, so a value can never
    start a new directive.
27. **Bounds (R77, 6.4).** Include depth 64, 20,000 include expansions per stage,
    8 MiB of expanded text, `#if` expressions nested at most 200 deep. Cycle
    detection compares paths with empty and `.` components removed; the message
    prints the chain as written (long chains are shortened with `...`).
28. **Leading macro facts (R38).** Computed while writing: a define records its
    trimmed replacement; a bare define, a function-like define or an empty combo
    records the name without a value; `#undef` removes; the first line that is
    not a define or undef (a blank line, a comment, ordinary code, another
    directive, the lighting block) ends the region; a skipped branch or a
    dropped `#require` writes nothing and does not end it.
29. **LightingV1 (R33, R34).** `LIGHTING` counts as enabled for any non-integer
    text and for any integer other than zero, negative ones included (`-1`).
    Counts are digits with an optional `+`; everything else, a negative number
    included, is 0; digit strings too long for an integer count as 15. The block
    is fully unrolled with constant indices and writes its zero as
    `vec3(0.0, 0.0, 0.0)` so it needs no dialect macro.

Lexer, facts and items:

30. **Lexer is total.** `unrecognized shader token` can never occur: every byte
    is a token, whitespace or part of a dropped comment. Hostile input cannot make
    the unterminated `/*` search quadratic.
31. **Numbers.** An exponent needs digits (`1e` is `1` then `e`). A string with a
    backslash before a line break is still unterminated at the line break.
32. **Comma.** A comma is a punctuation token, but `Token::operator()` answers
    `Operator::Comma` for it, so expression code treats it as the loosest operator.
33. **Summaries (R48).** The grouping tokens `( ) [ ]` are structure, never listed
    among a range's operators; `.` is. The member, index and call forms of the
    top-level classification apply only when nothing binds looser than they do
    (a deliberate difference from Q27: `p < q.x` is `other`, not a field select).
    Summaries are built to a nesting depth of 96 and a total work bound
    (2,000,000 plus 64 per token); past it a range simply has none.
34. **R44 and `struct`.** `struct Name inst;` is not a declarator statement (the
    keyword is not a type) but is a declaration item for R50.
35. **R47.** A function definition ends at its closing brace; any other simple
    statement that holds a block (a struct) continues to its `;`.
36. **Items.** A construct that reaches a brace before a `;` is reported as a
    one-token declaration and scanning continues with the next token (so `main`
    after a stray macro invocation is still found). A declaration stops at a
    directive or annotation token instead of swallowing it. A function may start
    with qualifiers; its item then starts at the first one. `type name (` whose
    parenthesis never closes is a parse failure at the `(`. Constructs longer
    than 2048 tokens are classified in pieces of that size (a hostile-input
    bound; real headers and declarations are far shorter).
37. **Conditional brace matching (R54).** Each arm of a conditional starts from
    the depth the conditional opened at, and after `#endif` the depth of the
    first arm is kept. A conditional opened before the scan started (the per-arm
    header shape) is treated as opened at depth zero. A body whose arms all close
    it ends at the completing `#endif`.

Metadata and protocol:

38. **Order of validation (R60, R63).** `default` is validated before the combo
    name is looked at, so a malformed number fails the shader even on a
    `[COMBO]` line that has no `combo` key. A value that starts with `e` or `E`
    has a numeric prefix and so fails (`e` does not parse).
39. **NUL in names (R10).** An alias whose material text, or a default texture
    whose path, contains a NUL byte is dropped silently.
40. **Texture slot text (R65).** `g_Texture007` is slot 7 here (the digits parse),
    while `names::classify_slot_name` calls the same text non-canonical: that
    function serves the response side, this rule serves annotations.
41. **Combo definition order.** Request combos in request order, then
    texture-derived combos, then annotation defaults, each in stage order and
    first-seen order (a combo found by both stages keeps the first stage's value).
    The texture-switch scan runs once, over the view built with the request
    combos alone; the annotation defaults come from one extraction over the
    evaluated text built for request plus texture-derived combos (Q4). The
    second evaluation is skipped when nothing was added.
42. **Errors of this step.** An unusable annotation is `RequestError::Metadata`
    (`invalid shader request: metadata number is invalid`, `... material alias is
    empty`); a bad combo name or slot reuses the existing variants. The include
    failures print the wording of R9 (`shader include not found: p.h`,
    `shader source read failed for p.h: ...`, `shader source utf-8 invalid for
    p.h`). A preprocessing failure is one diagnostic: stage, `Preprocess`, the
    line as its span, and an origin label (`include <path>`) when the line is in
    an include; `Diagnostic.origin` is a renderer-only field, not a key of the
    diagnostics document.

## Not yet done (planned for later steps)

The C ABI and last-error buffer (R1 to R9, R70 buffer, R89 to R93), the
engine-backed include provider (callback, free callback; the in-memory and
closure providers exist), uniform declaration merging across stages (R46),
array-bound resolution (R100), resource index allocation (R31 to R35, R102),
the legalizer (including the lowering of `CASTI`, `CASTU`, `CASTF`, `CAST4U`,
`DECLARE_SAMPLER2D_PARAMETER`, `MAKE_SAMPLER2D_ARGUMENT`: this step only passes
them through, test item 65), GLSL generation, the naga calls and the MSL
writer, the NV12 variant (R63 to R69 of the contract part), the MSL/golden
checks of R88, and the end-to-end checks of test items 58 (compile half) and
66. The cache identity is not bumped yet: nothing this step adds reaches a
compiled program until the pipeline uses it.

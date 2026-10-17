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

Step 3 (part C1 of the spec) is the module `dialect`: `expand` (macro expansion),
`parse` (tokens to the tree of `ast`), `ty` and `builtins` (the type model and what is
known about calls by name), `convert` (the typed rewrite: `expr`, `coerce`, `call`, `stmt`,
`items`, `special`, `helpers`), `print` (tree to GLSL text) and `usage` (the use facts of
R7). `dialect::convert_stage` is the entry point; its result carries the text *and* the
rewritten tree, so the interface and resource parts can work on the tree.
Step 4 (part C2 of the spec) is the module `legalize`: `collect` (declaration planning, R9 to R13),
`block` (the uniform block, R14 to R23 and R83, R87), `bindings` (R24 to R31), `interface` (locations,
reconciliation and synthesized outputs, R32 to R41, R82, R84), `rewrite` (sampling calls, plane
sampling, widened reads, the colour output; R42 to R44, R47, R49, R21, R78), `planes` (R45 to R48)
and `stage` (assembly, R6 and R8). `legalize::legalize` takes both stages of a program (or one
stage, which gets the standalone numbering of R31 and R41) and returns the GLSL text of each stage
plus `ProgramLayout`, the facts reflection needs (block members and binding, textures with their
two bindings, planes, vertex inputs under their author names, varyings, kept samplers).
`binding::assign_metal_slots` is R88 (dense sampler slots). `src/legalize/tests/` holds the tests of
section 8 and the corpus sweeps; `tests/gpu_probe.rs` gained the NV12 conversion probe and the
float remainder probe.

`tests/dialect_robustness.rs` is the hostile-input test of this part (run on a 2 MiB stack),
`tests/gpu_probe.rs` the opt-in Metal probes (a Swift runner dispatches one compute thread; no window,
no display): the smoothstep and `fmod` probe, and kernels written in the dialect that are converted,
written as Metal through naga and evaluated, whose values are compared with HLSL's (matrix inverse of
all sizes, remainder, truncation, bool and number conversions, `!`/`&&`, `mul` with `mat4x3`,
`CAST3X3`, array-parameter specialisation, moved global initializers, float subscripts and loop
bounds). Run them with `WM_SHADER_GPU_PROBES=1 cargo test -p wm-shader --test gpu_probe`; without the
variable they print why they did nothing.

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

## Step 3 choices (dialect front end, type rules, conversions)

Design:

43. **Macros are expanded here.** Wallpaper Engine's compiler expands macros before it sees
    types, so every type rule (R20, R101, R102, R104a) is satisfied by expanding them once,
    before parsing; no rule has to look into a replacement list. `#define` and `#undef` lines are
    consumed in source order (a macro defined in a function body applies from there on); the
    converted text therefore carries no `#define` (spec 2.2 and 10.22 allow this; the few
    "definition stays present" checks are replaced by checks of the expanded meaning). Expansion
    follows the usual rescanning model with a hide set; a function-like macro name without `(`,
    or with the wrong argument count, is left alone; `#` and `##` are not supported (no shipped or
    workshop shader uses them). Replacement tokens take the span of the use. Bounds: 1,000,000
    produced tokens, invocations nested 64 deep in arguments.
44. **Comments.** Ordinary comments are dropped (the lexer drops them). WE annotation lines
    between top-level items are kept as written; inside a function body they are dropped.
    Strings pass through as tokens.
45. **Leniency.** The parser is a real C-like grammar. Only delimiter problems are hard failures
    (R6, reported at the opening delimiter, or at a closer that closes nothing). An item or
    statement the grammar cannot place is carried through as raw text for naga to judge (P3),
    and so is a stray character (R5, E19). Statements nest at most 128 deep, parenthesised
    expressions likewise, and an expression tree is at most 256 deep (hostile input becomes raw
    text instead of a stack overflow; `ast::Expr::depth` makes the check O(1)).
46. **Types are coarse** (`ty.rs`): scalars, vectors, float matrices, arrays, structs, samplers,
    `void`, and `Unknown`. `Unknown` switches every rule off for the construct (P3): a
    conversion is inserted only where both types are known. An undeclared name, a call of an
    undeclared function and a swizzle with letters of no set are `Unknown`.
47. **What naga does is measured, not assumed** (naga 29.0.3, checked with a harness before
    the rules were fixed): int to float and int to uint scalars convert implicitly in arithmetic
    and in initializers, uint to int does not, `vec3(bool)` is refused, `float(bool)` works,
    `mat3(mat4)` and `mat3(mat4x3)` work, float `%` works and writes Metal `fmod`, vector `%`
    scalar does not, `min(vec3, 2)` works, `pow(vec3, 2.0)` does not, a `for` condition that
    starts with a type name is read as a declaration, and the declarators after an array
    declarator in one declaration list get the array type.
48. **Conversions** (R23 to R45). Number to bool is `x != 0` with the zero of the number's type;
    bool to number is the constructor `float(b)`, `int(b)`, `uint(b)` (`vecN(float(b))` for a
    vector target); float to int and uint to int are constructors; int to float is a
    constructor for a variable and a rewritten literal (`3` to `3.0`, `2u` to `2.0`, `3`
    to `3u`); a vector narrows with a leading swizzle (`(expr).xy`), a scalar broadcasts with the
    constructor of the target type, a vector into a scalar takes `.x`. Widening a vector is never
    done (R32) except the one case of R31.
49. **Float `%` stays the operator.** naga's glsl-in accepts `%` on floats and the Metal writer
    emits `metal::fmod`, the remainder with the sign of the dividend (R47). The probe of
    `tests/gpu_probe.rs` checks that value on the GPU. So no helper function is generated: both
    operands become floats of one shape (an `int` side is converted, a scalar beside a vector
    is broadcast) and `%=` likewise. `fmod(a, b)` is the same operator. Integer `%` is untouched
    (R46) and `%` of unknown types is left alone (R50).
50. **Comparison of an integer with a float** compares as floats (`float(i) < x`), except that an
    integral float literal beside an integer counter is rewritten as an integer (`i < 4.0` to
    `i < 4`), which is R39's loop-bound case; `i < 2.5` compares in float.
51. **R31** pads a `vec2(...)` or `CAST2(...)` operand of `+` or `-` with a zero third component
    when the sum flows into a 3-vector (initializer, assignment or return) and the other operand
    is a 3-vector by type. Nothing else widens.
52. **`mul`** is `(b) * (a)` with the operands typed as a product (`mat4x3 * vec4` is a `vec3`),
    and two float vectors of one width are `dot(a, b)` (decided in the spec). A user two-argument
    `mul` wins for the calls it accepts. A user function whose name is also a built-in or dialect
    name wins only when every argument is known and matches without a change of shape (R65, R71);
    otherwise the dialect meaning applies.
53. **`ddy`** keeps the old compiler's `dFdy(-(x))`. The sign depends on the renderer's clip-space
    orientation, which a front-end test cannot see; parity with today's pictures decides it until
    a derivative probe in the renderer says otherwise (R15, open question 4).
54. **`smoothstep` with reversed edges** is not rewritten. The Metal probe
    (`tests/probes/smoothstep_reversed.swift`, run with `WM_SHADER_GPU_PROBES=1 cargo test --test
    gpu_probe`) shows that `metal::smoothstep(0.9, 0.4, x)` already returns the saturated-ratio
    Hermite curve of Direct3D, for edges the compiler can fold, for runtime edges and for
    vectors; R106 says nothing is rewritten then. Only the shape rules of R28 apply.
55. **Helpers** (`convert/helpers.rs`) are emitted only when used, once each, ahead of the first
    function, under the prefix `_wm_` (or `_wm1_`, `_wm2_`... when the stage uses an identifier
    that starts with it): `clip` for float and the vectors, the matrix `inverse` for 2, 3 and 4
    (checked numerically against a reference; all three sizes are emitted when the argument
    type is unknown), and the stand-in `PerformLighting_V1` (both overloads, under its own name,
    emitted when the stage calls it and nothing declares it).
56. **Array and sampler parameters** (R66, R67). A function with such a parameter is kept as a
    template and dropped from the output. Each call specialises it for the global array or sampler
    it passes: the clone is named `<name>_wm<N>` (N counts distinct specialisations), loses the
    parameter, reads the global (substitution respects shadowing locals and never touches member
    names), and is emitted ahead of the function that first calls it. An array parameter the body
    writes is copied into a local initialised from the global instead. A call that passes a local
    or computed value is refused with a diagnostic that names "array-parameter specialisation".
    `MAKE_SAMPLER2D_ARGUMENT(t)` is just `t`.
57. **Stage inputs the shader writes** (R75). The interface variable is declared as `_we_in_<name>`
    and the author's name becomes a global of the same type, assigned from it at the start of
    `main` (ahead of the moved global initializers). A write is an assignment, a compound
    assignment or `++`/`--` rooted at the input, or the input passed to an `out`/`inout`
    parameter; shadowing locals are told apart by scope.
58. **Global initializers** (R72): an initializer that is not built from literals, constants and
    constructors (calls of functions, uniforms, inputs, mutable globals, `gl_` names) moves to the
    start of `main`, in declaration order, and the declarator loses `const`; a declaration list is
    split so only the moved declarators change. A stage without `main` keeps its initializers.
59. **Reserved words** (R70) are renamed to `<name>_wm` (a taken spelling gets a number) for
    locals, parameters, struct fields, globals and function names, consistently across
    declaration and uses; `sample` is the qualifier only in a qualifier run in front of a type.
60. **Alpha-to-coverage** (R83): the colour output is `gl_FragColor` or a fragment `out vec4`; the
    form is matched on the tree, so spacing, parentheses and the order of the `saturate` wrapper
    do not matter, and the constants compare by value (`0.5`, `0.0001`).
61. **Builtin variables** (R88): `gl_VertexID` and `gl_InstanceID` read as the `uint` builtins
    `gl_VertexIndex` and `gl_InstanceIndex`; a restating `in`/`attribute`/`varying uint
    gl_VertexID;` is dropped; any other `gl_` declaration is left as written.
62. **Header and idempotence.** The text starts with `#version 450` and `precision highp float;`.
    An input `#version` line is dropped and a `precision highp float;` statement is not repeated,
    so converting the output again gives the same text. `#extension` and `#pragma` lines pass
    through in place.
63. **Spans and diagnostics.** A syntax failure (R6) has pass `Parse`; a refusal of this part
    (unsupported name, sampler3D coordinate, array-parameter specialisation) has pass `Codegen`
    and the span of the construct; success carries the one informational `Codegen` entry.
64. **Float swizzle on a scalar** (`f.x`, `f.xxx`, legal HLSL) is not supported: the swizzle's
    type is `Unknown` and naga refuses it (the spec asks for no such rule).

## Step 4 choices (interface and resource legalisation)

How it is built:

65. **A tree, not text edits.** The converter hands over a tree, so the legalizer rewrites the
    tree and prints it. The rules of C2 4.1 are therefore not a list of text edits that have to be
    merged: R2's order shows only through effects, R3(c) to R3(e) and R81 hold by construction
    (nothing overlaps, nothing is inserted into a span), and the new tests assert the effects (a
    sampling call is paired with its sampler although `tex2D` is renamed, a renamed local is seen
    by the coercions and by the alpha idiom, reads through a specialised parameter are narrowed,
    the colour output is renamed last, text inside a replaced span disappears with it). Generated
    declarations and helper functions are carried as raw text items; the printed stage is the
    header, `#extension` lines, the texture, sampler and chroma declarations, the block, the
    interface and colour output declarations, the plane helpers, then the author's items.
66. **Order of the passes for a program.** Both stages are parsed; qualified declarations with
    several names are split into one declaration each (no declarator is ever dropped, section 5);
    array bounds and varying widths are reconciled on the *parsed* trees (R36 changes the type of a
    declaration, and the converter must see the reconciled type, C1 R89); both stages are
    converted; the block, bindings and locations are planned from the converted trees; each stage
    is finished. A stage alone skips the cross-stage part and uses R31 and R41.
67. **Macros are already expanded** (C1), which settles three C2 items. R4 and R85 (rules acting in
    macro bodies, alias macros of widened arrays, function-like macros, an alias define with a
    trailing comment) hold because the use site sees the replacement. R39 and R18 both use the macro
    table *at the declaration*: R18 says a uniform bound uses the table at the end of the stage, so
    a bound macro redefined after the uniform declaration reads the value at the declaration here
    (no shipped shader redefines one). A bare `#define N` used as a bound is empty, not 1 (R39's
    implicit value is not reproduced).
68. **R12 position-redirect output is not special-cased.** A `#define gl_Position p` with an
    `out vec4 p;` expands before this part sees it, so `p` is an ordinary vertex output that no
    fragment input matches (a vertex-only varying with a location). That is harmless on naga and
    keeps the rule that no name is special-cased.

Spec conflicts and the choice made:

69. **R56 stability refusal.** C2 R56 refuses a function whose calls pass different top-level
    arrays; C1 R66 prefers cloning the function per array. The converter clones (Step 3), so the
    refusal and its pinned message are not reproduced; the stereo audio helpers that call one
    function with the left and the right spectrum work. A black-box port of the upstream refusal
    tests will fail on this and the spec should be amended.
70. **R59 against C1 R83.** C2 R59 detects the sharpening idiom by what the right-hand side
    contains (two reads of the colour alpha, a derivative call, `max`, two literals `0.5`); C1 R83
    said "the shipped form and nothing broader". The converter now follows R59 (a superset: the
    shipped `(a - 0.5) / max(fwidth(a), 0.0001) + 0.5` is one instance) and keeps whatever follows a
    leading `saturate(...)` call.
71. **R68 loop bounds, R65 `int` from `step`.** The converter compares a counter with a float
    bound as floats (`float(i) < n`, HLSL's meaning) and keeps `int(step(...))` as an integer with a
    cast, instead of C2's `int(n)` and `float q = step(...)`. Both compile and agree whenever the
    bound is integral; the spelling differs from the old code (section 10 item 23 allows it).
72. **R41 standalone numbering.** A stage legalized alone numbers its interface from 0 in source
    order, but an array or matrix takes one location per element or column (R34), not one: two
    variables on one location are refused by naga (`downsample_quarter` declares a four-element
    varying followed by more). Non-array stages number as R41 says.
73. **R9 `sampler3D`.** Kept samplers stay as written, except that `sampler3D` is split into a
    `texture3D` and a sampler like a 2D texture (C1 R105d asks for it; naga reads no combined
    sampler of any kind, so the kept form can never compile). Cube and the other kinds stay kept.
    Sampling calls with `textureGrad`, `textureOffset`, `textureProj`, `textureProjLod`,
    `textureLodOffset`, `textureGather` and `textureQueryLod` are paired with the sampler as well;
    `texelFetch`, `textureSize` and `textureQueryLevels` take the separated texture object.
74. **Block member types naga cannot hold.** naga validates no `bool` in a uniform block and reads no
    matrix with two rows (`mat2`, `mat3x2`, `mat4x2`) in std140. A `bool` or `bvecN` member is
    declared `uint` or `uvecN` (the same four bytes per component) and read back as a comparison
    with zero; an array of booleans and every two-row matrix are refused with an "invalid
    request" message naming the member (R87 and section 10 item 9 allow the refusal). Integer
    arrays are widened to `ivec4` or `uvec4` (R87); the test `a_narrow_uint_array_stays_tight_on_metal_without_the_widening`
    shows that naga writes a plain `uint[3]` with a four-byte stride, so the widening is needed.
75. **Whole-array reads of a widened array** (`float bins[16] = g_Audio;`, an argument passed on)
    are an array constructor of the author's element type reading each element with its selector
    (R58 asks for the declaration to be erased and the uses replaced; the copy is the same work as
    the old copy and needs no scope analysis). Longer than 4096 elements is refused.
76. **Interpolation qualifiers** `flat`, `smooth` and `noperspective` are carried over to the
    re-emitted declaration (section 10 item 17); `centroid`, `sample` and precision words are
    dropped.
77. **A vector `uniform` declared wider in one stage** (R19) is read through `(name.x)` style
    parentheses by the narrower stage: the tree has no `#define` to carry, so the stage's reads of
    the name are rewritten (hidden by a parameter or local of the same name, they are not).
78. **Errors.** "Invalid request" failures are `LegalizeError::Request` (message only) or
    `LegalizeError::Uniform` (the contract wording of `UniformError`); `ShaderError` gained
    `RequestError::Program` for them. The stage-local and cross-stage classes carry a
    diagnostic (pass `Codegen`, the stage, a span of the preprocessed text). Messages: the pinned
    ones are produced word for word (unsupported member type, conflicting declarations,
    "cross-stage varying `x` type mismatch: vertex outputs T1 but fragment inputs T2",
    "unsupported stage-interface array bound", "cannot be sampled as planes", "canonical"); the
    metal limit text names the "argument-table limit of 15".
79. **Names the legalizer picks** (C2 2.4, free): the colour output `_we_FragColor`, synthesized
    vertex outputs `_we_out_<name>` (then `_N`), the plane helpers `_we_plane<N>` and
    `_we_nv12_convert<N>` (a pure function of the eight constants, so the arithmetic can be
    evaluated on its own), written inputs `_we_in_<name>` (the converter's). A taken spelling gets
    `_1`, `_2`, ...
80. **Not done in this step**: R79's optional early failure for a program the engine would refuse
    (a texture with another name, a kept sampler); the cache key and pipeline revision (nothing of
    this part reaches a compiled program until the pipeline calls it); the reflection document and
    the MSL writer call (the next step); the engine-side binding of non-`g_Texture<N>` resources.

Results of the corpus sweeps (`cargo test --lib legalize::tests::corpus -- --nocapture`), three combo
sets, both stages together, every stage compiled through naga to Metal:

- Shipped shaders: 164 of 165 programs legalize and compile. The one failure is
  `shadowcasterfoliage4` (skinned and reflective): its vertex stage reads `g_Texture1Texel`, which
  no shipped file declares, so no translator can compile it; the test names it and fails on any
  other cause.
- Workshop shaders (unpacked copies of the local library, distinct file texts): 855 of 870 programs.
  The 15 failures are not this part's: `textoutline7x7` has a 49-element varying (model limit 31
  locations, R30; 3 programs), `frame_builder` contains text that is not GLSL
  (`varying vec4 v_Size . xy ;`; 6), `phantomtransitionfx` reads an undeclared varying (3) and
  `lens_distorsion` has a `#if` expression the preprocessor refuses (3).
- Mutation fuzzing of the shipped programs (3,000 edited programs) and truncation of a stage at every
  character: no panic.
- Stage by stage (the dialect sweep through the standalone entry point): 317 of 318 shipped stages;
  the 27 workshop failures are the ones above plus a varying width only the program can reconcile.

## What a later step takes from this one

The interface and resource part (C2) is done (Step 4, above); it consumes `Converted::module`. The
pipeline step takes `legalize::legalize` (or `legalize_stage`), compiles each `LegalStage::text`
with naga (`glsl-in`, then the validator, then the Metal writer with the binding map built from
`ProgramLayout` and `binding::assign_metal_slots`) and builds reflection from the layout facts
and from naga's module. `src/dialect/tests/layout.rs` (the old stand-in) is deleted: the dialect
tests use the real legalizer.

## Not yet done (planned for later steps)

The C ABI and last-error buffer (R1 to R9, R70 buffer, R89 to R93), the engine-backed include
provider (callback, free callback; the in-memory and closure providers exist), the naga calls, the
MSL writer and the reflection document in the pipeline, the request-level NV12 plumbing (the
legalizer takes the flagged slots; the pipeline passes them), and the end-to-end checks of test
items 58 (compile half) and 66. The cache identity is not bumped: nothing this step adds reaches a
compiled program until the pipeline uses it. `src/dialect/tests/boundary.rs` pins a
digest of the converter's output per `PIPELINE_REVISION`, so the first change of converted
output after that revision forces a deliberate bump.

## Measurements (step 3)

Release build, converting the preprocessed stages of the shipped shaders under three combo sets
(318 stages) and of the local workshop library (1,677 stages): median 32 µs and worst 0.9 ms per
stage for the shipped ones, median 74 µs and worst 0.7 ms for the workshop ones. Every shipped
stage converts and compiles to Metal through naga (with the test-only layout stand-in), converting
the output again gives the same text for all of them, and 1,653 of 1,680 workshop stages
compile; the 27 that do not are named in `workshop_shaders_convert_and_compile_through_naga`
(an undeclared varying, a declaration that is not GLSL, the varying-width and widened-array
cases that belong to the interface and resource parts, and a `#if` the preprocessor refuses).
Mutation fuzzing of the shipped shaders (600,000 edited stages, release) and random token soup
(300,000 stages) produced no panic.

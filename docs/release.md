# Versioning and releases

Version numbers, the pipeline that publishes a build, the notes it writes, and what
the in-app updater expects of a release. Build mechanics live in [build.md](build.md). To cut
a release, follow the [checklist](#checklist-for-a-release); when one fails, see
[Recovering a failed release](#recovering-a-failed-release).

## Source of truth

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
[`project.yml`](../project.yml) are the version of both the app and the
lock-screen extension; the two targets carry identical values. The embedded
`MediaRemoteAdapter` framework declares the same `CURRENT_PROJECT_VERSION`,
because XcodeGen would otherwise generate its own default of 1 there.
`scripts/bump_version.py` also rewrites the same two keys in the committed
`WallpaperMachine.xcodeproj/project.pbxproj`, so the generated project stays
in sync without anyone running `xcodegen`, and running it produces no diff.
Change the version through the script or the Version workflow, never by editing
one of the two files alone. The panel reads the bundle's version, so Settings →
About and every GitHub report show the released number with no other edit.

`MARKETING_VERSION` is a strict `x.y.z` semantic version.
`CURRENT_PROJECT_VERSION` is an integer build number, incremented by one on every
bump.

## Release specs in commit messages

Push to `main` with a line of exactly this form — as the subject, a body line, or
a squash-merge title — to trigger a bump:

| Spec | Effect on `0.1.0` |
|---|---|
| `release: patch` | `0.1.1` |
| `release: minor` | `0.2.0` |
| `release: major` | `1.0.0` |
| `release: 1.2.3` or `release: v1.2.3` | sets `1.2.3` exactly |

Matching is case-insensitive and anchored to a whole line. An explicit `x.y.z`
must not move the version backwards.

Every commit message in a push is scanned, and a squash merge's body lists the
messages of all its commits, so keep a `release:` line out of any message that
should not ship a version. If a single push contains several `release:` lines,
an explicit `x.y.z` wins; otherwise the highest of `major` > `minor` > `patch` is
used. A push with no `release:` line prints `No release: spec in commit
message; skipping.` and does nothing.

Bump the same way locally:

```sh
python3 scripts/bump_version.py --spec patch            # dry run, prints old -> new
python3 scripts/bump_version.py --spec patch --apply    # writes both files
```

`--message` / `--message-file` scan a commit message instead of taking a spec
directly; `--ci` reads `RELEASE_SPEC` or the GitHub event payload. With `--apply`
omitted nothing is written, which makes it safe to inspect a planned bump.
`scripts/tests/test_bump_version.py` covers the script and runs as part of
`python3 scripts/test.py`.

## Release notes and the changelog

A version's notes are written once, when it is cut, into its
[`CHANGELOG.md`](../CHANGELOG.md) section. The update manifest carries the newest
sections, in every language, to the app's update window
([below](#what-the-in-app-updater-expects)); the release page uses only the English
notes from the current section. [`scripts/release_notes.py`](../scripts/release_notes.py)
does both halves; GitHub's auto-generated notes are not used. Once a version's tag
exists, its section is not extended: the tag's release already published it, so a
change that lands later belongs in the next release's notes.

The layout is conventional-changelog's, the one standard-version writes: a heading
that links the version to its comparison with the previous one and gives the release
date, then category headings, and bullets that end with their issue and commit
links. From 1.5.7 a section has three languages, in this order, and nothing else at
`###`; each language may open with its banner line. Earlier sections keep their
original English and Simplified Chinese notes:

```markdown
## [1.6.2](https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.6.1...v1.6.2) (2026-10-24)

### English

![WallpaperMachine 1.6.2](Resources/ReleaseBanners/1.6.2.jpg)

One or two sentences on what the release means, omitted when the lists say it.

#### Bug Fixes

- Long names on narrow tiles now shrink to fit (closes [#76](https://github.com/WallpaperMachine/WallpaperMachine/issues/76)) ([bb75725](https://github.com/WallpaperMachine/WallpaperMachine/commit/bb75725338d4ab37a649973457c0357900b93355))

### 简体中文

![WallpaperMachine 1.6.2](Resources/ReleaseBanners/1.6.2.zh-Hans.jpg)

同样的一两句。

#### 问题修复

- 较窄磁贴上的长名称现在会缩小以完整显示 (closes [#76](https://github.com/WallpaperMachine/WallpaperMachine/issues/76)) ([bb75725](https://github.com/WallpaperMachine/WallpaperMachine/commit/bb75725338d4ab37a649973457c0357900b93355))

### 한국어

![WallpaperMachine 1.6.2](Resources/ReleaseBanners/1.6.2.ko.jpg)

같은 내용을 한두 문장으로 요약합니다.

#### 버그 수정

- 좁은 타일의 긴 이름이 이제 줄어들어 전체가 표시됩니다 (closes [#76](https://github.com/WallpaperMachine/WallpaperMachine/issues/76)) ([bb75725](https://github.com/WallpaperMachine/WallpaperMachine/commit/bb75725338d4ab37a649973457c0357900b93355))
```

The heading is `## [x.y.z](<compare link>) (YYYY-MM-DD)`; a first release, with no
earlier tag, links `https://github.com/<repository>/commits/vx.y.z`. Sections no
longer end in a `**Full changelog**` line: the heading carries that link. The
sections written before this layout were converted with their own compare links,
older `bobbyhuang-dev` addresses included. The script still reads the older
`## x.y.z — YYYY-MM-DD` heading, but always writes the linked one.

Category headings inside a language are `####`, in this order:

| Section | `####` English | `####` 简体中文 | `####` 한국어 |
|---|---|---|---|
| highlights | Highlights | 亮点 | 주요 변경 사항 |
| breaking | Breaking Changes | 不兼容变更 | 호환되지 않는 변경 사항 |
| new | Features | 新功能 | 새로운 기능 |
| improved | Improvements | 改进 | 개선 사항 |
| fixed | Bug Fixes | 问题修复 | 버그 수정 |
| performance (listings and older sections only) | Performance Improvements | 性能改进 | 성능 개선 |
| other (listings and older sections only) | Other Changes | 其他变更 | 기타 변경 사항 |

Highlights appear only in feature releases: the three to five changes that define the
release, which the other sections still list. A feature release is `x.y.0`, or a patch
whose notes start below `x.y` because it replaces an `x.y.0` that was never published.

Every bullet ends with the same links in all three languages, written by the script
from the commits the bullet describes, never by the model:
` (closes [#N](https://github.com/<repository>/issues/N), closes [#M](…))` when those
commits close issues, then ` ([abc1234](https://github.com/<repository>/commit/<full sha>))`,
several commits comma-separated inside one pair of parentheses. The link text is the
7-character short hash, and the word `closes` stays English in every language: it is
GitHub's keyword. Closing references come from the full messages of the bullet's
commits: GitHub's keywords, case-insensitive (`close`, `closes`, `closed`, `fix`,
`fixes`, `fixed`, `resolve`, `resolves`, `resolved`), followed by `#N`. References to
other repositories are ignored, and numbers are deduplicated and sorted ascending.
That is why a commit names the issue it resolves with `Closes #N`
([conventions](conventions.md#commits-and-pull-requests)). Model-written bullets from
before this layout have no recorded commits and carry no links.

### Release banners

A release can carry a banner in each language: a 3:1 picture (2400 × 800
pixels, JPEG or PNG) committed as `Resources/ReleaseBanners/x.y.z.jpg` (English),
`x.y.z.zh-Hans.jpg` (Simplified Chinese) and `x.y.z.ko.jpg` (Korean), or `.png`,
before the commit with the `release:` line. Each banner carries its own language's
words; a missing localized file falls back to the English banner. When the section
is written, the script opens each language block with its image line:

- `CHANGELOG.md` on GitHub shows the images from their repository paths.
- The release page shows the English one from the version's tag on
  `raw.githubusercontent.com`, at the top of the English notes.
- The app bundles neither the folder nor `CHANGELOG.md`; what its update window shows
  of a section is in [The update window](features/updates.md#the-update-window).

Publishing refuses a banner line that names another version's file, and a banner
line is not translated prose: a language block holding only a picture is missing its
translation.
Banners are drawn for the product, not taken from Workshop wallpapers: their art
belongs to their authors. Sections whose tag exists keep the banner they shipped
with, so a banner never goes back into an older release.

### Written by the release-notes model

With `--ai` the commits between two version tags go to a language model that
writes them up for users — what they can do now, what works better, what no
longer goes wrong — in English, Simplified Chinese and Korean, the same changes in
all three, merging commits that describe one change and leaving internal work out.
The release pipeline always passes `--ai`.

| Environment | Default | Meaning |
|---|---|---|
| `RELEASE_NOTES_API_KEY` | none; required | Key for the gateway. A secret: it lives in the environment of one command or in the repository secret of the same name, never in a file. |
| `RELEASE_NOTES_API_BASE` | `https://sub2api.moraxcheng.me` | Anthropic Messages API gateway; a base that already ends in `/v1` is accepted |
| `RELEASE_NOTES_MODEL` | `claude-opus-5-5` | The model that writes the notes |
| `RELEASE_NOTES_GITHUB_TOKEN` | none | Lets the script ask GitHub which account wrote a commit, for the [thanks line](#thanking-contributors); CI passes the job's `github.token` |

The model reads every non-merge commit in the range, newest first, except CI's own
`chore: bump version to x.y.z`. `docs`, `test`, `chore`, `ci`, `build`, `style` and `refactor`
commits bring only their subject; every other commit (`feat`, `fix`, `perf`,
breaking ones, and types or subjects the convention does not recognise) brings
its body, cut at 1,500 characters, until 120,000 characters of bodies are spent.
A squash merge's body is read per commit it lists (`* type(scope): subject`
lines), each under the same rules. `Co-authored-by`, `Signed-off-by`,
`Reviewed-by` and `Claude-Session` trailers, and GitHub's `---` rule before them,
are dropped first: they only spend the budget. Commit messages are therefore the
source of the notes: write them for the reader
[conventions.md](conventions.md#commits-and-pull-requests) describes.

The instructions also carry the project's rules on claims, because CI commits the
notes without review: no energy, battery or power-saving claims, nothing called
fully supported or fully compatible, and opt-in features (direct video plane sampling,
on-demand scene idle, the animated lock screen) keep their optional, experimental
or off-by-default qualifier in every language; Native Metal is the default
renderer and native video is the default video player, and neither is ever called
optional. The model groups many commits about
one area (text layers, particles, lighting) into one bullet that names what users
see, keeping each section to about 15 bullets, and is told whether the version is a
feature release, which decides whether it writes highlights. Places in
the app are named the way the panel labels them, in English and in the zh-Hans
and ko catalogs' words (`Settings` / `设置` / `설정`); the prompt lists those names,
so renaming a tab or a Settings section changes the list in
`scripts/release_notes.py` in the same commit.

The prompt lists each commit as `* <short hash> <subject>`, so the model can cite it.
The model answers with JSON. `summary` is `{"english", "chinese", "korean"}`. Each of
`highlights`, `breaking`, `new`, `improved` and `fixed` is a list of
`{"english", "chinese", "korean", "commits"}` objects, one per change, so
translations cannot drift in length; `commits` is a required, non-empty list of the
short hashes of the commits the bullet describes. The summary names no commits. The
script resolves every hash to a commit of the range and stops the run on one that is
not a list, is empty, holds something other than a hash, or names a commit outside
the range (the bump commit included) or more than one commit. It renders that shape —
`### English`, then `### 简体中文`, then `### 한국어`, categories at `####`, each
bullet followed by its [issue and commit links](#release-notes-and-the-changelog) —
and stops the run on a reply that is not that JSON, omits a language, carries other
fields or an HTML comment (the boundary marker below), or was cut off at the
output-token limit. The compare link belongs to the section heading.
A Chinese string must contain Chinese characters; a Korean string must contain
Hangul; neither may copy the English or another translation. An English string
must contain Latin text. Whitespace is collapsed and list or heading markers are
stripped, so no entry can open a changelog section of its own. A range without
commits is reported in all three languages as having no user-visible changes,
without a request. The request
streams and names its own `User-Agent`, because Cloudflare in front of the
gateway refuses urllib's default one (error 1010). A connection that goes quiet
for 120 seconds, or a reply still running after 600, stops the run: the Version
job holds its branch lock while it waits. Nothing is retried; a failed run is
re-run.

#### Thanking contributors

Each language block of a new section ends with one line, written by the script and
not the model, thanking the outside contributors whose commits are in the range:
`Thanks to [@login](https://github.com/login) for contributing to this release.`,
`感谢 [@login](…) 为本版本做出的贡献。` and `이번 릴리스에 기여해 주신 [@login](…) 님께
감사드립니다.`, the same logins in the same order (oldest first contribution first)
in all three. Every commit of the range counts, internal ones included, except CI's
bump commit.

A contributor is a GitHub login. A commit's author has one when the address is
GitHub's noreply form (`<id>+login@users.noreply.github.com`); for any other address,
with `RELEASE_NOTES_GITHUB_TOKEN` set, the script asks GitHub's commit API once per
address (`GET /repos/<repo>/commits/<sha>`) and takes the author account GitHub links
it to. A `Co-authored-by` trailer counts only with a noreply address. Nobody is
credited by name or address alone: an address GitHub links to no account, a commit
it does not know yet (404/422) and every address in a run without the token are
left out, so a maintainer's new address is never thanked. Any other API failure
stops the run. `MAINTAINERS` in `scripts/release_notes.py` (`bobbyhuang-dev`,
`fzlzjerry` and the `t3code` agent account) and every bot (`[bot]` logins, GitHub's
`Bot` type) are never thanked; add a new maintainer there. AI co-authors such as
`noreply@anthropic.com` have no login and drop out on their own. The commit listing
(no `--ai`) ends with the English line too; `--rebuild-changelog` adds none to the
sections it lists, and a recorded section is never changed, so a version whose tag
exists keeps the notes it was published with.

### Listed from the commits

Without `--ai` the commits are listed in English, read through the
`type(scope): subject` convention in [conventions.md](conventions.md), as one
`### English` block with the same heading, `####` category names and link suffix
as the model's notes: `- **scope** — Subject (closes [#N](…)) ([abc1234](…))`. A
subject that repeats an earlier one collapses into one bullet that links every
commit behind it. It is offline and free, and it is a developer preview for
inspecting a range and for tests. It is not published: `--release-body` and
`--changelog --apply` refuse notes without the required ordered language blocks:
`### English`, then `### 简体中文`, then `### 한국어` for versions 1.5.7 and later.
Older bilingual sections remain valid.

Publication validates the whole changelog history, not just the current release.
Each `##` heading must be `## [x.y.z](<link>) (YYYY-MM-DD)` (or the older
`## x.y.z — YYYY-MM-DD`) with the version token `AppReleaseHistory` accepts
(optional `v`/`V`, three 64-bit integer components, no leading zeros), and each
section needs actual prose in every required language and matching bullet counts
(headings and compare links do not count as translated content). An explicitly
present Korean block must be complete even in older sections. Unknown, repeated
or misordered language headings also fail validation. `## Unreleased`, duplicate
versions, an overflow, a prerelease suffix, a leading zero, or a non-version `##`
line inside notes fails `--release-body`, `--changelog --apply` and
`--rebuild-changelog --apply`: such headings are neither kept nor dropped,
because the app rejects the whole file when it sees one.
`--rebuild-changelog --apply` also refuses to replace the file if rebuilding
would introduce an English-only section; translate missing history before applying.

| Commit type | Section |
|---|---|
| `feat` | **Features** |
| `fix` | **Bug Fixes** |
| `perf` | **Performance Improvements** |
| `!` suffix or a `BREAKING CHANGE:` trailer | **Breaking Changes** |
| `docs`, `test`, `chore`, `ci`, `build`, `style`, `refactor` | counted in one closing line |
| anything else, including non-conventional subjects | **Other Changes** |

Nothing is dropped silently: a subject the convention does not recognise is
listed rather than hidden, and the only commit removed outright is CI's own
`chore: bump version to x.y.z`. A subject longer than 140 characters is cut at a
word boundary; the linked commit still carries every word.

### Commands

```sh
python3 scripts/release_notes.py                               # English listing with its heading, not for publish
python3 scripts/release_notes.py --ai --tag v1.5.7 --to HEAD   # three languages, before the tag exists
python3 scripts/release_notes.py --tag v1.5.7 --release-body --ai --output notes.md
python3 scripts/release_notes.py --ai --changelog --apply      # write one translated section
python3 scripts/release_notes.py --rebuild-changelog --apply   # a section for every tag, recorded ones kept
```

A local `--ai` run needs `RELEASE_NOTES_API_KEY` exported for that command only.
To see the thanks line for contributors without a noreply address, pass
`RELEASE_NOTES_GITHUB_TOKEN="$(gh auth token)"` the same way.
`--previous` overrides the tag the range starts after; by default it is the
newest released version below the target that the range's end descends from, so a
gap in the numbering resolves correctly.

`--release-body` is the English-only GitHub release page. It reuses the version's
translated `CHANGELOG.md` section without calling the model again and keeps only the
English block, in the same category names and with each bullet's issue and commit
links. It then adds `**Full changelog**: <compare link>`, the link the section heading
carries (for an older heading, the comparison with the previous tag), then
`<!-- release-notes-end -->` and the install, checksum and requirement footer
(with a `Built from` line when `--built-from` is given). Raw commit messages are
not appended; the **Full changelog** link leads to the commits of the comparison. A
hand-pushed tag with no section is written once, by the model when `--ai` is
set, into the working-tree `CHANGELOG.md` before anything is built. English-only
or malformed source history fails the run instead of being published.

The marker is a contract: the updater shows everything above it and nothing
below, and About skips the **Full changelog** line. The update window reads the
manifest's `changelog` field, not that body, and falls back to the body only when the
field is missing; see [The update window](features/updates.md#the-update-window).

Writing a section is idempotent — rerunning replaces the section for that
version instead of duplicating it. `--rebuild-changelog` writes a section for every
version tag but keeps each section `CHANGELOG.md` already holds word for word, so
the model's notes survive; only missing ones are listed from the commits, in
English, and that listing is not a publishable section. It never calls the model,
and refuses `--ai`. `CHANGELOG.md` is written with `--apply`, and also when
`--release-body` has to generate the current section. With `--changelog`, nothing
is generated unless `--apply` or `--output` is given, so that dry run never calls
the model; a plain `--ai` run prints the model's section, heading included, and does
make the request. `scripts/tests/test_release_notes.py` covers classification,
closing references, rendering and links, the changelog headings, range resolution
against a throwaway repository, the model path and its commit citations against a
fake gateway, who is thanked (noreply logins, GitHub's commit record against a fake
API, maintainers and bots left out) and the thanks line in every language, the publish path and the committed `CHANGELOG.md` itself;
`scripts/tests/test_update_manifest.py` covers the manifest. Both run as part of
`python3 scripts/test.py`.

## Workflows

Version, Build, Release, Warm caches and Supporters are the release workflows in
`.github/workflows/`; Supporters shares only `main` with the others.
`claude.yml` and `claude-code-review.yml` are pull-request automation, described
in [CONTRIBUTING.md](../CONTRIBUTING.md#automated-review). `checks.yml` runs
`python3 scripts/test.py --python-only` on Linux for every pull request and push to
`main`, the fast check a pull request waits for. `codeql.yml` is code scanning,
described [below](#codeql-codeqlyml).

Version, Build and Release grant `contents: write`; Build's publish job also needs
`id-token: write` and `attestations: write` for its provenance attestation, and
both callers pass those through, together with the repository's secrets (`secrets:
inherit`). Warm caches only reads. Supporters writes only `README.md`,
`README.zh-CN.md` and `README.pt-BR.md`, with `contents: write`, and reads Version's runs with
`actions: read`. The macOS setup Build and Warm caches share lives in one
composite action,
[`.github/actions/prepare-build`](../.github/actions/prepare-build/action.yml).

**Repository secrets.** Only a repository administrator can set or replace them:
`gh secret set <NAME>` in a checkout prompts for the value and writes it to the
repository `origin` points at.

| Secret | Read by |
|---|---|
| `RELEASE_NOTES_API_KEY` | Version for every bump; Build only for a tag without a `CHANGELOG.md` section |
| `SIGNING_CERTIFICATE_P12`, `SIGNING_CERTIFICATE_PASSWORD` | Build's `build` job, which fails when either is missing ([build.md](build.md#release-signing)) |
| `CLAUDE_CODE_OAUTH_TOKEN` | `claude.yml` and `claude-code-review.yml` |

### Version (`version.yml`)

Runs on every push to `main`, and on demand from **Actions -> Version -> Run
workflow** with a `spec` input. On an `ubuntu-latest` runner it:

1. checks out with full history;
2. runs `python3 scripts/bump_version.py --ci --apply`;
3. has the release-notes model write the new version's three-language section into
   `CHANGELOG.md` with `scripts/release_notes.py --to HEAD --ai --changelog
   --apply` — `### English`, then `### 简体中文`, then `### 한국어`. The tag does
   not exist yet, so
   the range ends at `HEAD`. Without the secret, or when the model fails or omits
   a language, the job stops here: nothing is committed or tagged, and re-running
   the failed job retries the same bump;
4. if anything changed, refuses to continue when the target tag already exists on
   `origin`, then commits `project.yml`,
   `WallpaperMachine.xcodeproj/project.pbxproj` and `CHANGELOG.md` as
   `chore: bump version to x.y.z`, tags `vx.y.z`, and pushes branch and tag
   atomically as `github-actions[bot]`;
5. calls the Build workflow directly for the tag it just pushed.

Step 5 is not redundant. **A tag pushed with `GITHUB_TOKEN` never starts another
workflow**, so the tag-triggered Release workflow would never fire for a
CI-produced tag; without the direct call, a bumped version would be tagged but
never published.

The bump job holds a `version-<ref>` concurrency group only while the bump commit
is produced. A workflow-wide group would keep the lock through the macOS build,
and because GitHub retains only the newest pending run, a queued `release:` push
could be replaced by a later ordinary push and silently lost.

The workflow needs permission to push to `main`: `contents: write`, and branch
protection must allow GitHub Actions.

### Build (`build.yml`)

`workflow_call` only, with a required `tag` input. It is the single place a
publishable artifact is produced, called by Version for CI-produced tags and by
Release for hand-pushed ones. It runs three jobs. `app-icon` compiles the app icon
on a `macos-26` runner. `build` then runs on `macos-15` (the oldest runner that
carries Xcode 26, whose Homebrew bottles set the published app's minimum macOS),
with a 150-minute timeout. `publish` runs on `ubuntu-latest` once it succeeds.

The test gate is not part of a release. Every change passes `python3 scripts/test.py`
before it is committed, and on hosted VMs the gate failed 1.5.0 through 1.5.4 only on
timing and layout the VM got wrong, each failure leaving a tag that could not be
published and a fix that had to ship under the next number. The
[Test workflow](#test-testyml) runs the same gate by hand.

The icon is compiled apart because Xcode 26's `actool` crashes on most `.icon`
compiles on macOS 15 ([build.md](build.md#stages-and-outputs)). `app-icon` runs
`python3 scripts/build.py --compile-app-icon DIR` and hands `Assets.car`,
`AppIcon.icns` and the partial Info.plist to `build` as the `app-icon-<tag>`
artifact.

**`build`**

1. checks out the tag with full history, which the notes need;
2. writes the release body with `scripts/release_notes.py --release-body --ai
   --built-from "$(git rev-parse HEAD)"` before anything is built. The current
   section must already have every required language and is reused without
   calling the model; a hand-pushed tag with no section gets one written once into
   the working-tree `CHANGELOG.md`. A copy of that `CHANGELOG.md` goes to `publish`
   with the notes, so the update manifest carries every translation of the new
   section. Missing translations or malformed source history fail here, in seconds,
   rather than after the macOS build;
3. runs `prepare-build` (below) and downloads the `app-icon-<tag>` artifact;
4. runs `python3 scripts/build.py --configuration Release --app-icon DIR`, which
   leaves `AppIcon.icon` out of the Xcode build, puts the compiled icon and catalog
   into the bundle with their Info.plist keys and re-signs it;
5. imports the project signing certificate from the two signing secrets into a
   temporary keychain ([build.md](build.md#release-signing)), then runs
   `python3 scripts/package.py --configuration Release --require-deployment-target
   --sign-identity "WallpaperMachine Code Signing"`, which fails if a bundled
   library needs a newer macOS than the deployment target. It also generates
   `THIRD-PARTY-NOTICES.txt` into the bundle; a component whose license text
   cannot be found is named in the log and marked in the file, and
   `--require-notices` (not yet passed here: see
   [../LICENSING.md](../LICENSING.md#notice-payload)) would fail on it.
   Packaging proves the
   disk image, not the build tree: it mounts the image read-only and requires
   `app.wallpapermachine` at the bundle's version, a passing
   `codesign --verify --deep --strict`, the signed entitlements and Info.plist
   keys the lock screen extension and the permission prompts need ([bundle
   contract](build.md#bundle-contract)), the `Applications` link and the window
   layout, then writes the `.sha256` sidecar
   ([build.md](build.md#packaging-and-installing));
6. matches the image to the tag: it must be named
   `WallpaperMachine-<tag without v>-arm64.dmg`, and its checksum is echoed into the
   job summary;
7. hands the image, its sidecar, the notes and that `CHANGELOG.md` to `publish` as
   the `release-<tag>` artifact.

Step 6 is the guard that the bump actually reached the build:
`scripts/package.py` names the image from the bundle's
`CFBundleShortVersionString`, so a mismatch means the published tag and the
built version disagree and the job fails instead of publishing the wrong binary.

When `build` fails it uploads its full tool logs from `artifacts/` as
`build-logs-<tag>`, kept 14 days: the job output is only the scripts' filtered
summary.

**`publish`**

1. downloads the artifact and checks the image against its `.sha256` sidecar;
2. attests build provenance for the image with
   `actions/attest-build-provenance`;
3. writes the update manifest `WallpaperMachine-update.json` from the tag, the
   notes, the image and the build job's `CHANGELOG.md` with
   `scripts/update_manifest.py --changelog` ([below](#what-the-in-app-updater-expects));
   `publish`'s own checkout of the tag lacks a section generated for a hand-pushed tag;
4. publishes the image, its sidecar and the manifest with
   `scripts/publish_release.py`.

**`prepare-build` and the caches.** The composite action selects the newest
non-beta `/Applications/Xcode_26*.app`, `brew install --quiet`s the
XcodeGen/CMake/renderer package set with `ccache`, and restores two
`actions/cache` entries. Every key carries the runner's macOS (`<os>` below is
`macos-15` or `macos-26`), because bottles and compiled objects
differ between releases; `build` and the Test workflow therefore keep separate entries.

| Cache | Path | Key | What a hit saves |
|---|---|---|---|
| C++ objects | `~/.ccache` | `ccache-<os>-<run>`, restored by the `ccache-<os>-` prefix | recompiling the scene engine. A checkout gives every file a new mtime, so CMake rebuilds the whole engine even from a restored build tree; ccache hashes content and returns the previous objects. Test's three jobs share a run's key, so only `renderer`, which compiles the engine and its C++ tests, saves it; `rust` and `native` pass `save-object-cache: "false"` and only restore it |
| Renderer | `~/.cargo/registry`, `~/.cargo/git`, `Renderer/target` | `renderer-ccache-<os>-<hash of rust-toolchain.toml>-<hash of Cargo.lock, provenance.json>`, restored only from entries with the same toolchain hash | crate downloads, and Rust compilation |

The `CMAKE_<LANG>_COMPILER_LAUNCHER=ccache` variables only take effect on a build
tree's first CMake configure, so change the renderer key's prefix whenever the
launcher setup changes: no tree configured the old way may be restored. Each
macOS job prints `ccache --show-stats` at the end; hits against misses there is
the evidence the cache worked. The toolchain is a pinned stable release
(`Renderer/rust-toolchain.toml`); raising the pin changes the renderer key's
toolchain hash, so the next build compiles every crate once and starts a new entry.

Only runs on `main` save either cache; every other ref (pull requests, branches,
hand-pushed tags) restores and never saves. An entry saved under another ref is
readable by that ref alone, and those entries pushed the repository past GitHub's
10 GB cache limit, which evicts the `main` entries releases need. A tag Version
produces is built by Version's run on `main`, so release builds still save.

**What the attestation does and does not say.** Its SLSA predicate is built from
the run's OIDC claims: `resolvedDependencies[0]` is `git+<repo>@<claims.ref>` with
`digest.gitCommit = claims.sha`
([`actions/toolkit`](https://github.com/actions/toolkit/blob/main/packages/attest/src/provenance.ts)).
For a Version-produced tag those claims describe the push to `main` that carried
the `release:` line — the revision *before* the bump commit the tag points at,
because Build runs as a `workflow_call` inside that same run. So the attestation
binds the image's digest to this repository, this workflow, this builder and
this run; it does **not** identify the revision the image was built from. That
revision is recorded separately in the release body as
``Built from `vx.y.z` at `<sha>` ``, and anyone can check it with
`git rev-parse vx.y.z^{commit}`. A hand-pushed tag going through Release does not
have the discrepancy, because there the triggering ref is the tag itself.

**How `scripts/publish_release.py` publishes.** Drafts first, live releases
refused: it creates the release as a draft (or finishes a draft an earlier attempt
left), uploads the files, and clears the draft flag last, so a failure leaves a
draft that neither the API's `releases/latest` nor github.com's
`releases/latest/download/…` returns. A release already *published* is refused and
fails the job, because `gh release upload --clobber` deletes an existing asset
before writing its replacement and would take the download away. Latest cannot go
backwards between publishers: builds for different tags run concurrently, so
Build's final `publish` job holds a repository-wide
`release-promotion-<repository>` concurrency group with
[`queue: max`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
(waiting releases queue rather than replace the pending job), and the script
re-reads the public versions after the upload, immediately before clearing the
draft flag. It passes `--latest` only if no greater public, non-prerelease version
exists, and `--latest=false` otherwise; a failed lookup leaves the uploaded draft
unpublished. Manual invocations must be serialized with every other publisher too:
use the release workflow for the shared lock. The script's docstring and
`scripts/tests/test_publish_release.py` cover both rules.

### Test (`test.yml`)

The test gate on hosted runners, run by hand from **Actions -> Test -> Run
workflow** on the branch or tag chosen under "Use workflow from" (`--ref` below). It
does not tag, build the Release app or publish, and no release waits for it
([why](#build-buildyml)). It has no input naming another ref to test: its jobs save
caches under the ref the run starts from, and a run started from `main` that built
another ref's code would let that code write the caches every release restores. Its
three jobs run in parallel on `macos-26` runners, each after `prepare-build` and
`python3 scripts/build.py --renderer-only` for the renderer and the generated bridge,
so a run takes about as long as the native tests (about 25 minutes for 1.5) rather
than the sum (over 40):

- `rust` runs `python3 scripts/check_rust.py`;
- `renderer` runs `python3 scripts/check_renderer.py --allow-missing-gpu
  --allow-imprecise-timers`. The two flags are fallbacks for hosted VMs: only the exact
  exit 77 of a compiled device or timer probe skips the named GPU or wall-clock cadence
  checks ([renderer testing](testing/renderer.md#scriptscheck_rendererpy)); each skip
  is a CI warning, and all other probe and test failures remain failures. Excluded and
  asset-dependent checks stay listed in the JSON reports and logs; they do not count as
  verified asset or GPU coverage;
- `native` runs `python3 scripts/test.py --serial`, which builds the Debug app, icon
  included, and its tests itself. `--serial` runs one test class at a time: see
  [Parallel execution](testing/README.md#parallel-execution) for why.

```sh
gh workflow run test.yml --ref main
gh workflow run test.yml --ref <branch> -f skip_renderer=true -f only="SettingsWindowRenderTests WorkshopBrowserRenderTests"
```

`only` passes each space-separated name to `scripts/test.py --only`, and
`skip_renderer` skips the `rust` and `renderer` jobs; both are for diagnosis, so only
a run without them says the gate passes. A failed job keeps its logs, result bundles
and any WebKit, app or jetsam reports included, as `test-logs-<run id>-<job>` for 14
days.

### Warm caches (`warm-caches.yml`)

GitHub evicts a cache entry nobody has read for seven days. Twice a week (and on
demand from **Actions -> Warm caches -> Run workflow**) this runs `prepare-build`
and `python3 scripts/build.py --renderer-only` on `main`, once on `macos-15` and
once on `macos-26`, which reads every entry Build and Test use and saves a fresh C++
object cache for each, so a release or a Test run after a quiet week still starts warm. Caches saved on
`main` are readable from every ref, including the tags Release builds. It
publishes nothing.

### Supporters (`supporters.yml`)

Keeps the [README's Supporter list](../README.md#thank-you-to-every-supporter), and
the same list in its translations `README.zh-CN.md` and `README.pt-BR.md`, in step with the website's
[sponsor wall](https://www.wallpapermachine.app/#sponsors). Every hour (and on
demand from **Actions -> Supporters -> Run workflow**) it runs
`python3 scripts/update_sponsors.py` on `main`, which reads the wall's JSON from
`https://www.wallpapermachine.app/api/sponsors` and rewrites the block between the
`supporters:start` and `supporters:end` markers in all three files; the script's
docstring describes the block, and edits between the markers are overwritten.
When the block changed it commits the three READMEs as
`docs(readme): update the Supporter list` and pushes to `main`, starting again from
the new `main` if that moved. It skips the hour while a Version run is queued or
running, because Version's push of its bump commit does not retry. A wall that
can't be read, or a README without its block, fails the run and leaves the READMEs
as they were.

### CodeQL (`codeql.yml`)

Code scanning on every push to `main`, weekly, and on demand. Pull requests do not
run it: the Swift job's full traced app build takes about half an hour, and its
findings were mostly false positives, so new alerts surface after the merge instead.
It replaces GitHub's default setup, which can only autobuild Swift and
fails at the extension's link because the renderer library and the Homebrew
libraries do not exist yet. Actions, Python and Rust are analyzed without a build
on Linux. Swift runs on `macos-26`: `prepare-build` and
`python3 scripts/build.py --renderer-only` first, untraced, then CodeQL traces
`scripts/build.py --swift-only` with the `--xcode-setting` overrides CodeQL's own
Swift autobuild uses (no signing, no compilation cache, no integrated driver), so
the extractor sees every Swift compile. C/C++ (only vendored third-party code is
visible to it), Ruby (the repository has none) and JavaScript/TypeScript (none since
the SwiftUI control panel; CodeQL fails a language with no code) are deliberately not
analyzed.
Removing a language from the matrix does not remove its configuration: **Security ->
Code scanning -> Tool status** keeps showing that language's last scan, failed or
not, because nothing uploads to its category again. In the same change, delete it
there (the configuration's **⋯ -> Delete configuration**) once no alert in it needs
keeping.
Default setup must stay off under **Settings -> Code security -> CodeQL
analysis**; while it is on, GitHub rejects this workflow's results.

### Release (`release.yml`)

Triggered by pushing a `v*.*.*` tag by hand. It only calls Build with
`github.ref_name`, sharing the `publish-<tag>` concurrency group with Version's
publish job so one tag is never built twice at once. A hand-pushed tag has no
`CHANGELOG.md` section unless one was committed before tagging; Build then asks
the model once and writes that translated section into the working tree before the
app is built. A section that is present but missing a required translation fails
the build; it is not rewritten.

## What the in-app updater expects

**Settings → About** installs updates from the repository's latest GitHub Release.
What the app does with one (when it checks, how it avoids the API quota, download,
verification, replacing the running app, the update window) is in
[updates](features/updates.md). This section is the publish-side contract: what a
release has to carry for that to work.

The update manifest, `WallpaperMachine-update.json`, is an asset of every release.
`scripts/update_manifest.py` writes it in Build's `publish` job from the tag, the
notes file that becomes the release body, `CHANGELOG.md` and the image bytes, and
`scripts/publish_release.py` attaches it. It is the release object in the REST
API's shape: `tag_name`, `html_url`, `prerelease`, `body` and one asset with
`name`, `browser_download_url`, `size` and a `sha256:` `digest`, plus one field the
API does not have. `changelog` (written with `--changelog CHANGELOG.md`) is a string
holding the newest 20 `## ` version sections of `CHANGELOG.md` verbatim, every
language included, from the first `## ` heading on, without the file's preamble.
The script refuses a changelog with no section for the tag. When an update is
available, the app's update window shows from it each version newer than the
installed one, in the app's language, and falls back to the release body when the
field is missing, as in manifests from before it existed
([The update window](features/updates.md#the-update-window)). The app no longer
bundles `CHANGELOG.md` or `Resources/ReleaseBanners`, and there is no window after
an update. The app reads the manifest
from `https://github.com/WallpaperMachine/WallpaperMachine/releases/latest/download/WallpaperMachine-update.json`,
which github.com redirects to the file on the release marked Latest. A draft never
resolves, and `publish_release.py` makes the release public only after the image,
sidecar and manifest are uploaded. The name is
`AppUpdateConfiguration.manifestName`; renaming it changes both sides at once. The
script refuses a tag that is not `vx.y.z`, a repository that is not `owner/name`
and an image not named as below.

What a release must satisfy:

- the repository is `WallpaperMachine/WallpaperMachine`
  (`AppUpdateConfiguration.repository`). Builds up to 1.0.0 still ask for
  `bobbyhuang-dev/WallpaperMachine` and reach it only through GitHub's rename
  redirect, so never create a repository at that old path;
- the release is not a draft or prerelease, and its tag is `vx.y.z` (no
  prerelease suffixes, no `nightly`);
- the disk image is named exactly `WallpaperMachine-<x.y.z>-arm64.dmg` — what
  `AppUpdateConfiguration.assetName(for:)` returns and what `scripts/package.py`
  produces (`image_name` in `scripts/lib/dmg.py`). The app can fall back to another
  product `.dmg`, but never downloads the `.sha256` sidecar, zips, feeds or
  blockmaps;
- the manifest's asset carries a `sha256:` digest of the image and a
  `browser_download_url` on github.com, both derived by `update_manifest.py`; the
  app refuses an image it cannot verify;
- releases are signed with the project certificate
  ([build.md](build.md#release-signing)), so the replacement keeps the designated
  requirement and macOS keeps the app's privacy permissions;
- the release body is the English notes above `<!-- release-notes-end -->`
  ([Release notes and the changelog](#release-notes-and-the-changelog)); the app
  shows what is above the marker as **What's new** in About and ignores the rest;
- the manifest's `changelog` starts with the new version's section in the
  [layout above](#release-notes-and-the-changelog), so an install several versions
  behind sees every change it is about to receive.

Renaming the image, publishing a prerelease, or attaching only a zip silently
breaks automatic updates; `Tests/Unit/GitHub/AppUpdateTests.swift` pins this
behavior, including the exact published image name and an install from a real disk
image.

## Recovering a failed release

A tag the Version workflow pushed stays when its Build run fails; only Build's
`publish` job makes a release public. If a tag was created but its release never
passed the publication gate, preserve that tag and fix the failed checks on
`main`: Version refuses a target tag that already exists on `origin`,
`publish_release.py` refuses a live release, and a `CHANGELOG.md` section is not
extended once its tag exists. Cut the next patch instead, with the optional
workflow-dispatch `notes_from` input set to the last *published* tag, so its
model-written translated notes include the still-unpublished changes:

```sh
gh workflow run version.yml --ref main -f spec=patch -f notes_from=v1.2.6
```

`notes_from` only sets `release_notes.py --previous`; it does not change the version
policy, skip tests or replace a live release. Ordinary releases leave it empty and
use the preceding tag. When the unpublished tag was a feature release, its notes start
below that minor version, so the patch gets highlights too; commit copies of its
banners under the patch's number (`x.y.1.jpg`, `x.y.1.zh-Hans.jpg`,
`x.y.1.ko.jpg`) before running the
workflow, since a section names only its own version's banner. Remove the sections
of the unpublished versions the patch replaces, and their banners, from
`CHANGELOG.md`: its notes already cover them, and a section left there is shown again
in the update window of every install that updates across it. Remove them before the
patch is cut, in or before the push with the `release:` line: the patch's manifest
carries `CHANGELOG.md` as it is at the patch's tag, and that copy is not rewritten.

## Checklist for a release

1. Land the change on `main` with a `release:` spec line, or run the Version
   workflow with a spec.
2. Confirm the Version run committed `chore: bump version to x.y.z` with the new
   `CHANGELOG.md` section and pushed `vx.y.z`. Read the section: its heading is
   `## [x.y.z](<compare link>) (YYYY-MM-DD)`, then `### English`, `### 简体中文` and
   `### 한국어`, the model wrote all three, and each bullet links the commits it
   describes and any issue they close. The update window shows all translations;
   the GitHub release page shows only the English notes.
3. Confirm the called Build run verified the mounted
   image, and published `WallpaperMachine-x.y.z-arm64.dmg` with its `.sha256`
   sidecar, `WallpaperMachine-update.json` and a provenance attestation. The
   manifest's `digest` must equal the sidecar's checksum, and its `changelog` must
   start with the new version's heading:
   `curl -sL https://github.com/WallpaperMachine/WallpaperMachine/releases/latest/download/WallpaperMachine-update.json`.
4. Read the release body on the page: it should contain only the English notes
   from the current `CHANGELOG.md` section, followed by the install footer,
   with its issue and commit links, without Chinese or Korean sections or a raw
   commit list. The **Full changelog** link opens the comparison with the previous
   version; the `Built from` line must match
   `git rev-parse vx.y.z^{commit}`.
5. Confirm Latest points at the highest published version. Re-running Build for a
   tag that is already published fails by design; if a published release is
   genuinely wrong, delete it deliberately rather than re-running.
6. Open the published image on a Mac: the window shows the app beside
   Applications over the background, the drag installs it, and the first launch
   goes through System Settings → Privacy & Security. Then run the manual smoke
   pass in [testing/manual-smoke.md](testing/manual-smoke.md) against that copy
   and record it with `python3 scripts/log_verification.py` (see
   [conventions](conventions.md#documentation)).

CI publishes the disk image although the questions in
[../LICENSING.md](../LICENSING.md) remain unresolved; the licensing gate that
once failed Build was removed for 1.0.0 by maintainer decision. That file also
records the intended Supporter model (a free Developer ID signed and notarized
download, and a one-time Supporter purchase for a sponsor place and priority
support, under the GPL with corresponding source alongside). Neither Developer
ID signing nor notarization is part of this pipeline: `scripts/package.py`
signs with a self-signed certificate that only keeps the designated requirement
stable ([build.md](build.md#release-signing)), a provenance attestation records
who built an artifact rather than who vouches for it, and neither is license
clearance.

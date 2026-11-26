# Local backup and restore

This page covers the backup package and the restore that follows it. Backup is one
of the Settings → Storage tools; the Settings sections are listed in
[control panel](control-panel.md#pages-and-settings).

**Settings → Storage → Backup** exports a versioned `.wmbackup` directory package
containing renderer/wallpaper settings, allowlisted preferences (collections,
wallpaper metadata such as ratings, custom tags, notes and rotation exclusions,
plans, presets, favorites, image placements, display layouts, [desktop
widgets](desktop-widgets.md), [lock screen and screen saver](lock-screen.md)
per-display and playlist source selections, [wallpaper switch transitions](wallpaper-switching.md),
automatic-selection rules and sunrise/sunset settings included), retained
[user-selected files](user-files.md), and what scene scripts saved with `localStorage`
(`SceneStorage`, restored per wallpaper under the chosen conflict policy; an older app
refuses a package that contains it). Handled automatic
events and temporary Focus recovery state remain local and are cleared on
successful restore; rollback restores their original values. **Include the
wallpaper library** also copies installed projects, from wherever the library is
kept; a restore writes them to the library's place on the Mac it runs on, which
may be [another folder or drive](library-location.md). Login sessions, passwords,
keychain entries, logs, caches and shared scene resources are excluded, and the
local scene-assets selection stays local and may need to be selected again. Time
Machine and other backups of the whole Mac likewise skip the saved Steam sign-in,
partial downloads and caches, but not the library ([Steam
sign-in](workshop-downloads.md#steam-sign-in)). Only
preferences saved in the app’s persistent domain are included; inherited system
languages and registered defaults are excluded, including during conflict checks
and rollback. Export checks the complete manifest size before copying payload
bytes and supports the full 48 MB preset archive limit. Three filter-sidebar
preferences (`workshopFiltersCollapsed`, `installedFiltersCollapsed` and
`pixivFiltersCollapsed`, under the `WallpaperMachine.` prefix) are on the allowlist
although the panel does not read them, so backups made by earlier versions restore.

Choose a backup to preview its contents, conflicts and missing-resource warnings.
**Keep what is on this Mac** preserves conflicting per-display playlists, their
deadlines, per-wallpaper metadata records and automatic-selection configurations as
whole records; independent records can be imported. Sunrise/sunset settings are also kept or replaced as one
record, including when a backup from an older version contains only coordinates.
**Replace with the backup** replaces conflicts. Confirmed
restoration is staged for the next launch, before stores or the renderer read
settings; nothing changes in the running session, and the app does not quit or
restart automatically.

Packages reject traversal, links, special files, ambiguous filenames, changed
bytes and unsupported configuration schemas. Publication is journaled and rolls
back on failure. A failed pending restore is shown in Storage and is not retried
every launch without explicit reconfirmation; **Cancel restore** removes staging.
An interrupted rollback retries before a new restore: it records the originals'
volume, file identity and creation time before returning them, without copying
their contents. Returning a file, restoring preferences and cleaning up can each
be retried. A completed transaction keeps its journal until its other temporary
contents are gone, including when the library lives on another drive. That drive
must still be connected; missing or replaced originals remain an error, not a
reason to accept whatever is at the live path. Recovery reads legacy version-1
journals and upgrades them to version 2 before rollback; older app versions refuse
that in-progress journal. A legacy rollback that already lost both its saved copy
and preparation evidence cannot be identified safely and remains preserved for
manual recovery.
Managed resource paths relocate, while ordinary property text stays unchanged.
Backed-up copies are portable; original external files are read or watched only
after a matching local authorization or an explicit reselection, so restoring
metadata alone cannot authorize a wallpaper to read another folder on this Mac.
Scene texture overrides and authored defaults that had only retained copies are
rewritten to the exact validated retained file, because the scene renderer opens
paths directly rather than going through the Web asset host; original paths stay as
provenance only. A retained directory without a directly usable scene resource, or
a keep-existing asset tree missing the matching bytes, cannot authorize a scene
reference and is rejected before publication.

## Shareable setup packs (`.wmpack`)

Unlike a full `.wmbackup` local backup, **Settings → Storage → Shareable setup pack** exports
and imports a lightweight, single-file `.wmpack` JSON document meant for sharing a desktop setup
with another Mac.

- **What is exported:** strict numeric Steam Workshop wallpaper IDs (with optional display titles
  for preview), selected sanitized property presets (`WallpaperPresetDocument` entries with all
  `retainedPath` values, external filesystem paths and binary attachments removed), portable
  [desktop widgets](desktop-widgets.md) (static image sticker widgets are omitted, and per-Space
  UUID bindings are downgraded to show on all Spaces with a clear note), and saved display layouts
  using portable display slot IDs rather than raw hardware UUIDs.
- **What is never exported:** wallpaper media files, binary preset attachments, Steam sign-in
  sessions or cookies, passwords, machine-local macOS Space UUIDs, and private filesystem paths.
- **Strict import hygiene:** opening a `.wmpack` file refuses symbolic links and special files
  (`O_NOFOLLOW`), enforces a 2 MB file-size limit, validates strict UTF-8 and NUL-free input,
  checks JSON nesting depth (linearly before parsing) and total node counts, rejects unknown
  top-level keys, unsupported schema versions, path traversal, non-numeric Workshop IDs and
  non-portable path references, and downgrades any incoming Space-pinned widget scope to
  `everywhere`.
- **Interactive preview and in-place apply:** the import sheet lists which Workshop wallpapers
  are already installed versus missing, suggests a best-fit mapping from exported displays to
  currently connected displays (with an interactive picker to remap or skip each display), and
  lets you choose which presets, display layouts and widgets to import. Chosen components apply
  immediately without restarting the app and without clobbering unrelated settings. Missing
  Workshop wallpapers are **never** downloaded silently: queueing downloads is opt-in and requires
  an explicit confirmation step before anything is added to the Steam download queue.

## Cross-Mac sync folder (`WallpaperMachineSync.json`)

**Settings → Storage → Cross-Mac sync folder** provides manual Push / Pull syncing across Macs
using any user-chosen folder (iCloud Drive, Syncthing, Dropbox, OneDrive, SMB/NAS or an external
drive), without background directory watchers, real-time merge races or CloudKit entitlements.

- **Local-only folder binding:** the chosen sync folder path and bookmark stay strictly local in
  `UserDefaults` on each Mac and are never included in `.wmbackup` packages or synced snapshots.
- **Atomic manual push:** **Push now** writes a versioned `WallpaperMachineSync.json` snapshot
  (`schemaVersion: 1`, `exportedAt`, `deviceName`, `appVersion`) via a same-directory temporary
  file (`O_EXCL | O_NOFOLLOW` + `fsync`) and atomic replacement so cloud sync daemons never upload
  a half-written file.
- **What is synced:** the Steam Workshop wallpaper index (numeric IDs and optional titles, no media
  binaries), favorites, collections, per-wallpaper metadata (1–5 star ratings, custom tags, notes
  and rotation exclusions), saved playlists (including Smart Playlists), sanitized portable property
  presets (local paths and `app:`/`shortcut:` values stripped), portable [desktop
  widgets](desktop-widgets.md) (static image stickers omitted; Space UUID scopes downgraded to
  `everywhere` with a note), display layouts using canonicalized display slots (`display-1`,
  `display-2`, …), and video A–B loop trim ranges.
- **Hard security exclusions:** Steam/Pixiv sessions, cookies and credentials,
  `UserShortcutStore` (`app:`/`shortcut:` bindings), media binaries, caches, logs, local folder
  bookmarks, CoreGraphics hardware UUIDs and macOS Space UUIDs are never exported or accepted.
- **iCloud placeholder detection & strict pull hygiene:** before opening
  `WallpaperMachineSync.json`, WallpaperMachine checks both `.WallpaperMachineSync.json.icloud`
  stubs and `URLResourceValues.ubiquitousItemDownloadingStatus` so un-downloaded iCloud Drive files
  surface a clear message instead of hanging. Reading enforces `O_NOFOLLOW | S_IFREG` (rejecting
  symlinks and special files), an 8 MB size cap, linear pre-parse JSON depth and node count limits,
  a top-level key allowlist, schema version checks, strict numeric Workshop ID validation, and
  per-field bounds validation across every category.
- **Diff & conflict preview:** **Pull & Review…** displays source Mac metadata, per-category diff
  counts (added, updated, conflicting), selectable categories, and an explicit conflict strategy:
  **Merge** (default: union sets, keep this Mac’s value on same-item conflicts, append non-duplicate
  items) or **Replace** (replace only the checked categories, leaving unchecked categories untouched).
  Display layouts and display-pinned widgets offer interactive display remapping with an explicit
  **Skip** option, imported layouts always save with `autoApplyOnConnect` turned off so local
  auto-apply layouts are never clobbered, missing Workshop downloads require explicit user opt-in
  confirmation, and changes apply immediately in place with no restart.



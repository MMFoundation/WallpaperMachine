# Linked folders

Settings → **Library & Steam** → **Linked folders** links folders of your own wallpapers
(on the Desktop, in Documents, on another drive) to the library once. A file you add to a
linked folder is imported; a file you delete from it can leave the library too. Each folder
has its own **Mirror deletions** switch, off by default.

The library keeps copying what it imports, as every import does: the folder is never
written to, and playback never reads from it.

## What a link records

`LinkedFolders.json` in the app-support folder (`ClientPaths.linkedFoldersURL`, so
`WALLPAPER_MACHINE_HOME` moves it too) keeps, for each link (`LinkedFolder`): the folder's
path, a plain bookmark of it (the app is not sandboxed; the bookmark follows a folder renamed
or moved on its disk) and **Mirror deletions**, plus a record (`LinkedFolderRecord`): for
each file, the library id it became, its size, modification time and file id
(`URLResourceKey.fileIdentifierKey`), and whether this link imported the item. It is local
to this Mac: backups and sync folders leave it out. A file that cannot be read is renamed
to `LinkedFolders.unreadable.json` and the app starts without links rather than overwrite it.

Linking a folder inside the library or WallpaperMachine's own folders, or one that holds
them, is refused, and so is linking a folder twice. macOS may ask once for access to the
Desktop or Documents folder the first time a linked folder there is read.

## When the folder is looked at

`LinkedFolderCoordinator` belongs to the app, so folders are followed whether or not the
panel is open:

- once the library has been read at launch, and again after the Mac wakes, when any disk
  mounts, and when the library's own drive comes back (`StorageVolumeMonitor`), because
  FSEvents cannot report what changed while the app was not running;
- whenever the folder changes, through one `DirectoryWatcher` per link (FSEvents, debounced,
  no polling);
- a few seconds after a look that found a file new or still changing, once, so a file whose
  copy has finished is imported. Nothing runs while no file is waiting.

A look reads the folder's top level only (`LinkedFolderScanner`): every file the import takes
(videos, pictures, HTML) and every Wallpaper Engine project folder (one holding a
`project.json`; its size is the total of its files and its date the newest of theirs). Hidden files, links and
other files are skipped; subfolders that are not projects are not entered.

## What a look changes

`LinkedFolderPlanner` decides, from the folder and the record alone:

- **A new or changed file** is imported once two looks in a row see the same size and
  modification time, so a file still being copied is not imported half-written. The import
  goes through `LibraryImportStore` with **Replace if changed**, shows as any import does in
  the toolbar, and its ids follow the import's rules (`local-<name>`, `image-<name>`, a
  project's folder name or recognized Workshop id). A file whose import failed is not tried
  again until it changes. While another import runs, the link waits for it.
- **A renamed file** (the same file id under another name) keeps its wallpaper, favorites and
  playlist entries. A file renamed and changed is imported under its new name's id; with
  Mirror deletions on, the item under the old name is then removed.
- **A deleted file**, with Mirror deletions on, leaves the library through the same removal
  as the panel's Delete (`removeLinkedFolderWallpapers`: moved to the Trash, other wallpapers
  take its place on displays, and its favorites, playlist entries, collections, presets and the
  rest are forgotten). With it off, the wallpaper stays and the folder's row counts it as kept
  after leaving the folder. Turning the switch on later does not remove those.
- **Only what the link imported** is ever replaced or removed. A file named like a wallpaper
  that was already installed (a Workshop item, a hand import, another link's) is recorded and
  left alone, in the library and in the folder.

The removal clears data the panel owns, so it runs while the control panel is open; removals
found while it is closed wait in the record and run when it opens.

## Safety

- A folder that is missing, unreadable, in the Trash, or on a disk that is not connected
  changes nothing. Its row says so, and the link waits for it to come back.
- A file iCloud Drive evicted to a `.name.icloud` placeholder is still in the folder.
- More than 20 removals at once, or more than a quarter of the link's wallpapers (a single
  file is never held), are not applied: the folder's row asks **Move to Trash** (confirmed
  again) or **Keep**, which keeps them and does not ask about them again.
- Nothing is imported or removed while the library's drive is away.
- **Unlink** stops following the folder; what it imported stays in the library.

## Tests

`LinkedFolderPlannerTests` (new and changed files only once their size holds still, renames
by file id, deletions with Mirror deletions on and off, only the link's own items, an
unavailable folder, iCloud placeholders, the mass-removal guard with confirm and keep, a
file back before its removal, failed imports, reading the import report) and
`LinkedFolderCoordinatorTests` (two looks before an import, removals waiting for an open
panel, an unreadable folder, unlinking, refused folders), over fake folders, imports and
removals and a temporary record file.

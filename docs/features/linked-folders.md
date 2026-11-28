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
to this Mac: backups and sync folders leave it out. It is written off the main thread, one
save after another. A file that is there but cannot be read is never saved over: links cannot
be changed until it can. One that reads but does not decode is renamed to
`LinkedFolders.unreadable.json` and the app starts without links. A link the user adds,
unlinks or switches is kept only once it is saved.

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
  no polling). While the folder is missing, its nearest existing parent is watched instead, so
  a folder put back is noticed; not the home folder, `/` or `/Volumes`, whose changes never
  stop: a folder directly under them waits for a wake, a disk mounting or the panel opening;
- a few seconds after a look that found a file new or still changing, once, so a file whose
  copy has finished is imported. Nothing runs while no file is waiting.

A look reads the folder's top level only (`LinkedFolderScanner`): every file the import takes
(videos, pictures, HTML) and every Wallpaper Engine project folder (one holding a
`project.json`). A project's stamp is its total size, its newest date and a digest of each
file's relative path, size, date and file id, so two files swapping names count as a change.
A project copied from the Workshop under another name gets the id its manifest names, as the
import gives it. Hidden files, links and other files are skipped; subfolders that are not
projects are not entered. Every name the folder lists counts as present, even when it cannot
be read (a project folder without permission, a file iCloud Drive evicted to a `.name.icloud`
placeholder): a recorded file is taken for deleted only when its name is gone.

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
  Mirror deletions on, the item under the old name is removed in the same look. A rename onto
  an id another wallpaper already has is not imported.
- **A deleted file**, with Mirror deletions on, leaves the library through the same removal
  as the panel's Delete (`removeLinkedFolderWallpapers`: moved to the Trash, other wallpapers
  take its place on displays, and its favorites, playlist entries, collections, presets and the
  rest are forgotten). With it off, the wallpaper stays and the folder's row counts it as kept
  after leaving the folder. Turning the switch on later does not remove those.
- **Only what the link imported** is ever replaced or removed. A file whose id is already
  installed (a Workshop item, a hand import, another link's, or the same name in other case on
  a library volume that ignores case) is recorded and left alone, in the library and in the
  folder. The library is read after each scan, just before the import starts, and an import
  that still lands on a wallpaper that was there before is not made the link's.

The removal clears data the panel owns, so it runs while the control panel is open; removals
found while it is closed wait in the record and run when it opens. A file whose wallpaper is
due to be removed stays in the record (`leaving`) until it is: if it comes back first, under
its name or renamed, the removal is called off and a changed file is imported. Just before
anything moves, in its turn in the command queue, the removal asks the link again what is
still due, so an unlink or Mirror deletions turned off meanwhile removes nothing; turning it off
keeps every wallpaper still due. A batch cut at the panel's limit (4,096) goes on at once.

## Safety

- A folder that is missing, unreadable, in the Trash, or on a disk that is not connected
  changes nothing. Its row says so, and the link waits for it to come back.
- A name the folder still lists is never taken for deleted, whether or not it can be read.
- More than 20 removals at once, or more than a quarter of the link's wallpapers (a single
  file is never held), are not applied: the folder's row asks **Move to Trash** (confirmed
  again) or **Keep**, which keeps them and does not ask about them again. Removals decided one
  at a time while the panel was closed are counted together. Confirming removes only the
  wallpapers the confirmation counted; any that left while it was open are asked about next.
- Nothing is imported or removed while the library's drive is away.
- **Unlink** stops following the folder; what it imported stays in the library.

## Tests

`LinkedFolderPlannerTests` (new and changed files only once their size holds still, renames
by file id, deletions with Mirror deletions on and off, only the link's own items, ids that
differ only in case, an import that landed on an installed wallpaper, a rename onto another
wallpaper's id, an unavailable folder, unreadable and evicted names, the mass-removal guard
with confirm, keep and removals queued while no panel was open, files back before their
removal, failed imports, reading the import report) and `LinkedFolderCoordinatorTests` (two
looks before an import, removals waiting for an open panel, an unreadable folder, unlinking
or turning Mirror deletions off during an import, a rename and edit handled in one look,
confirming only what was counted, a missing folder watched through its parent, a file another
import added during the scan, a link that could not be saved, a record that could not be read,
refused folders), over fake folders, imports and removals and a temporary record file;
`LinkedFolderScannerTests` (a Workshop copy's manifest id, swapped file names, an unreadable
project) on a temporary folder.

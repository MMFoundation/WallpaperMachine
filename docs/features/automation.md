# Automation

WallpaperMachine can choose wallpapers by weekday, time, sunrise/sunset, system
appearance or Focus. Global keyboard shortcuts, actions in the Shortcuts app
(and so Siri and Spotlight), and `wallpapermachine://` links run explicit
commands (`AutomationCommand`)
through `AppAutomation` into `AppDelegate.performAutomation`, which the menu bar's
Play/Pause, Mute Wallpapers, Previous, Next, Random Wallpaper, Recently used, Remove from Display and Start Again items use too (with
two or more displays the menu has a submenu for each, see
[the menu bar](control-panel.md#menu-bar-one-display-at-a-time)). They only do what the
menu bar and the panel already offer: play, pause, mute or unmute every wallpaper, the previous, next or a random wallpaper,
apply an installed wallpaper, copy a saved playlist to a display, apply a saved
property preset, or open the window. Automatic selection uses the same serialized
wallpaper commands and keeps manual choices until the next event.

[Display layouts](display-layouts.md) add one command for restoring saved wallpaper
choices across multiple independent displays.

## Automatic selection

**Settings → Displays → a display → Automatic wallpaper selection** offers:

| Mode | Behavior |
| --- | --- |
| Off | Leaves the wallpaper and any existing playlist under their usual controls. |
| Time schedule | Up to 64 rules, each with an enable/disable switch, weekdays, a clock time or sunrise/sunset plus a −180…180 minute offset, and a wallpaper or saved playlist. Rules can be reordered with their move buttons or by drag-and-drop to control tie-breaking order. |
| Follow system appearance | Separate choices for the system's light and dark appearance; an empty choice leaves the display as it is. The panel's own theme is independent. |
| Different wallpaper for each desktop | Choices by desktop UUID, made on the display's card or by applying a wallpaper on that desktop, and loaded after entering it, or run on where they paused when the desktop was visited before. A desktop without a choice follows Desktop 1's; only when Desktop 1 has none either does the display keep the current wallpaper. Only the current desktop plays: in Mission Control the others show a still picture. See [a wallpaper for each desktop](spaces.md) for pause/Focus behavior and native lock-screen limits. |

A wallpaper target turns that display's playlist off after successful activation.
A saved playlist copies its current settings, then the existing playlist scheduler
takes over. Editing a saved plan does not update an already applied copy. Appearance
and time-rule targets use a searchable cover-thumbnail chooser (`WallpaperThumbnailChooser`);
a saved target that no longer exists stays displayed as **Unavailable** without being
overwritten until another choice is picked. Mirrored
and disabled displays do not accept rules. Disconnected displays keep their settings
and catch up when eligible again. Each time rule has a switch to turn it off without
deleting it (`isEnabled`, defaulting to enabled when loading older saved rules and
backups); disabled rules are skipped by the planner and stay dimmed in the list.
**Remove** on a time rule asks in the row (**Remove this
rule?**, **Cancel** or **Remove**) before the rule is gone, as deleting a display layout or
a saved playlist does.

Time rules use the Mac's time zone. The latest due enabled rule wins; equal timestamps
choose the later rule in the list, which can be adjusted directly by reordering rules. A daylight-saving gap moves a nonexistent time
to the next valid clock time; a repeated time fires at its first occurrence only.
After sleep, lock, pause, a covered display or a display that is not in use, only the latest due choice is applied
when playback can run again. Manual wallpaper and playlist choices mark the current
event handled, including across relaunch. A rule that comes due while your own
Apply is waiting on that display, or running there, gives way to it and is not
applied afterwards; it counts as handled, like a manual choice. Another automatic command
taking its place in the line is different: an update reloading the display's files, or a
playlist change, replaces a rule or Focus change that was still waiting its turn, and
because nothing the user chose stands in its place it stays due and is asked for again
(`UserCommandQueue.Outcome`). A Focus wallpaper, or the restoration after a Focus, is
therefore never lost to an update that happened to reload the display meanwhile. Saving changed rules creates a new event
and may apply it immediately. A failed event is reported in the display's section
and waits for **Retry automatic change** or a later event.

**Sunrise and sunset**, at the bottom of Displays, offers three time sources. With
**Coordinates** it accepts manual latitude and longitude: north/east positive,
south/west negative. Calculation is local, requires no location permission or
network request, and follows the approximate
[NOAA solar equations](https://www.gml.noaa.gov/grad/solcalc/solareqns.PDF).
It uses the Mac's time zone even when coordinates describe another region.

With **Fixed times** it uses the two clock times entered there instead of
calculating anything, so no coordinates are needed. Rules keep their offsets, so a
rule at sunset − 15 minutes fires 15 minutes before the fixed sunset time.

Choosing **Automatic** asks for location access and keeps the Mac's approximate
position up to date, then calculates like **Coordinates**. Location updates stop
when another source is selected, and the last position keeps planning while a new
fix is unavailable. Relaunching resumes already-authorized updates without asking
for permission. If Location Services is off or access was refused, the panel says
so and links to System Settings; allowing access there resumes updates while
**Automatic** remains selected.

Weekdays refer to the solar event's civil day before applying the offset; offsets
may cross midnight. Days without a sunrise/sunset near the poles are skipped. A
coordinate-based or automatic solar rule without a location has no event until one
is supplied. When coordinates are set, **Sunrise and sunset** displays today's
locally calculated sunrise and sunset times inline (or notes when neither occurs
near the poles), and the rule editor shows today's event and offset-adjusted run
time when editing a sunrise or sunset rule.

## Focus selection and restoration

In **System Settings → Focus → Focus Filters**, WallpaperMachine also offers
**Use wallpaper** and **Use saved playlist**, with an optional display. Omitting the
display pins the panel's current target when that Focus choice takes effect. The
selection temporarily overrides time and appearance rules; existing pause/mute/stop
Focus actions are documented under [Performance](performance.md#low-battery-low-power-mode-heat-and-focus).

When the filter ends, a currently due automatic rule takes over; otherwise the
previous wallpaper and playlist return. A manual wallpaper chosen during Focus is
preserved unless a new automatic event became due. Editing or applying a different
playlist during Focus keeps that new playlist instead of restoring the old one.
Restored rotations start a fresh interval; restored day/night playlists wait until
their next boundary. Deleted wallpaper, plan and collection references are checked
again on restoration. Focus recovery is journaled before applying a choice so an
interrupted launch can recover it. Actual macOS Focus delivery still requires a
separate desktop test.

Rules and coordinates are stored in `WallpaperMachine.automaticWallpapers` and
`WallpaperMachine.solarLocation` and included in local backups. Keep-existing restore
merges by display. The handled-event and Focus recovery records are local runtime
state, excluded from exports, cleared when restored settings replace their baseline,
and retained if restore rolls back.

Every display's rules are one saved value, read one display at a time. A display whose
record this build cannot read (saved by a newer build that knows another mode, or damaged)
is set aside as it was saved: the other displays' rules load, **Some automatic wallpaper
settings could not be read** stays on show while it is set aside, and every save writes it
back unchanged, so editing one display never erases another's and installing the newer
build again finds its rules. Giving that display rules of its own replaces what could not
be read. Focus recovery records, saved playlists, local collections and app rules are kept
the same way (`PreservedJSON`). A value that is not the expected kind of JSON at all, is
over 2 MiB, or holds more than 64 displays is still dropped whole.

## Commands

| Command | What it does |
| --- | --- |
| Play, Pause, Play or pause | Resumes or pauses every wallpaper, as the menu bar's Play/Pause does. |
| Mute, Unmute, Mute or unmute | Silences every wallpaper, lets them play as they were saved, or switches whichever applies. It sets the local `wallpapersMuted` preference ([Mute all wallpapers](performance.md#playback)) and takes no turn in the command queue. It never changes a wallpaper's or display's saved mute and volume, and the mute app rules, Focus filters and other-app audio keep muting after Unmute while they apply. |
| Previous wallpaper | Returns to an earlier successful switch on the chosen display; repeated requests keep walking back, skipping deleted or unsupported wallpapers. History is consumed only after Apply succeeds. |
| Next wallpaper | Changes a display to its playlist's next when it rotates (see [playlists](playlists.md)), otherwise to the next playable wallpaper in library order. |
| Random wallpaper | Changes a display to a wallpaper picked at random from all the wallpapers that can play, from favorites only, or narrowed to a local collection (by name or id), other than the one the display shows. The display's own round remembers what it has picked, so every wallpaper of the pool comes round before one repeats; the playlist's order and shuffle round are not touched ([Random Wallpaper](playlists.md#random-wallpaper)). It is the user's own choice, so a playlist gives way to it. A wallpaper the app is holding back after a crash is never picked. With no other wallpaper to choose from it fails with "There is no other wallpaper to choose from." instead of changing nothing quietly. |
| Apply a wallpaper | Applies an installed wallpaper, named by its id (its folder name in the library). |
| Apply a wallpaper to all displays | Applies an installed wallpaper to every enabled independent display in one step: all of them change or none does, and each is put back as it was after a failure. Refuses a wallpaper with unapplied edits. See [Apply to every display](display-layouts.md#apply-to-every-display). |
| Apply saved playlist | Copies a saved plan to the chosen display and starts it when playback can run. |
| Apply wallpaper property preset | Applies a saved preset to its owning wallpaper on every display using it; rejects unapplied editor drafts. |
| Apply display layout | Restores the saved wallpaper arrangement across its named displays, with full preflight and verified failure recovery. |
| Toggle favorite wallpaper | App Intents only (no link): adds or removes a chosen wallpaper, or the wallpaper currently shown on the target or named display, from Favorites. |
| Set wallpaper volume | App Intents only (no link): sets the audio volume (0–100%) for the wallpaper currently shown on the target or named display. |
| Toggle desktop widgets | App Intents and global shortcuts only (no link): temporarily hides all desktop widgets or shows them again without altering individual widget settings. |
| Toggle desktop icons | App Intents and global shortcuts only (never exposed to links): shows or hides Finder's desktop icons, restarting Finder to apply the change. |
| Presentation mode | App Intents and global shortcuts only (no link): pauses playback, mutes wallpapers, and hides desktop widgets, restoring each prior state when turned off. Hiding Finder's desktop icons is strictly opt-in and off by default (`WallpaperMachine.presentationHidesDesktopIcons`), because it restarts Finder. |
| Open | Brings up the control panel, on Installed, Steam Workshop (`page=discover`), pixiv or Settings when named. |
| Remove from display | Menu bar only, with no link: takes whatever the named display shows off it and leaves it empty, so its playlist waits ([a display you cleared](playlists.md#a-display-you-cleared)). It takes the display's turn in the command queue and removes what the display shows then; an empty display is left as it is. |

Previous, Next, Random Wallpaper, Apply Wallpaper and Apply Saved Playlist act on the panel's target display unless a display is named, and
only an enabled display showing its own wallpaper can be switched. Switches share
the display's command slot with the panel, so the latest request for a display
wins; an automatic change (a playlist, a rule, an update reload) never replaces
a request that is waiting or running there. A command that arrives while the app is still
starting (the system may launch it to run one) waits up to 15 seconds for the
library to load, then fails with a message saying so. If the renderer could not start at all, opening the
panel still works, since Settings is where a failed start is put right; every
other command fails at once instead of waiting. A failure from a link or a keyboard shortcut shows at
the foot of the menu bar menu; the Shortcuts app shows its own.

## Keyboard shortcuts

**Settings → Keyboard shortcuts** records one shortcut each for
**Play or pause wallpapers**, **Mute or unmute wallpapers**, **Previous wallpaper**, **Next wallpaper**, **Random wallpaper** (from every
wallpaper, on the target display), **Open the control panel**, **Toggle desktop widgets**, **Toggle desktop icons**, and **Presentation mode**, plus optional per-layout shortcuts for saved display layouts.
None is set until recorded, so the app never takes a combination another app
expects. **Record…** takes the next key pressed in that row (Escape alone, or
moving focus away, gives up); the key must be held with ⌘, ⌥ or ⌃, except F13
to F20, which type nothing and may stand alone. The recorder takes the key's
position (`NSEvent.keyCode`, which is Carbon's virtual key code), which
`GlobalHotKeys.hotKey(keyCode:modifierFlags:)` checks against the keys a shortcut
may use, so a shortcut stays on the same key whatever the keyboard layout. One
combination serves one action or saved layout.

`GlobalHotKeys` registers them with `RegisterEventHotKey`, which works whichever
app is in front, needs no Accessibility permission and delivers only those
combinations. A combination another app already holds is refused by macOS; the
row says so, and says it again after a relaunch until it is changed. Action shortcuts
are kept in the `WallpaperMachine.hotKeys` default; saved display layout shortcuts are
kept separately in `WallpaperMachine.displayLayoutHotKeys` so existing backup validation
stays compatible.

Under **Presentation mode**, **Also hide desktop icons (restarts Finder)** is off by
default (`WallpaperMachine.presentationHidesDesktopIcons`). When left off, Presentation Mode
pauses playback, mutes wallpapers and hides desktop widgets without touching Finder; turning
it on also hides Finder's desktop icons when entering Presentation Mode and restores them on
exit (only if Presentation Mode hid them), restarting Finder each time.

## Shortcuts app, Siri and Spotlight

App Intents in `App/Services/Automation/WallpaperIntents.swift` add read-only query actions —
**Get Current Wallpaper** (`GetCurrentWallpaperIntent`, returning a structured `CurrentWallpaperEntity`
with the wallpaper, display, playback, mute, favorite and presentation-mode states) and
**Find Wallpapers** (`FindWallpapersIntent` and `WallpaperQuery`'s `EntityPropertyQuery`,
filtering installed playable wallpapers by name, type, favorite status and collection) — as well
as action intents: **Pause Wallpapers**, **Resume Wallpapers**, **Play or Pause Wallpapers**, **Mute Wallpapers**,
**Unmute Wallpapers**, **Mute or Unmute Wallpapers**, **Previous Wallpaper**, **Next
Wallpaper**, **Random Wallpaper** (with optional **Collection** picker), **Apply Wallpaper** (with the wallpaper chosen from, or searched in,
the installed ones that can play), **Toggle Favorite Wallpaper**, **Set Wallpaper Volume**,
**Toggle Desktop Widgets**, **Toggle Desktop Icons**, **Toggle Presentation Mode**, **Apply Saved Playlist**, **Apply Wallpaper
Property Preset**, and **Open WallpaperMachine**. Configuration entities (collections, saved layouts,
saved playlists and property presets) live in `WallpaperConfigurationIntents.swift`.
That file also supplies **Apply Display Layout** with a saved-layout picker and
no display parameter; the layout itself identifies its target screens.
`WallpaperMachineShortcuts` offers ten built-in actions (play/pause, mute/unmute, previous, next, random, wallpaper,
playlist, property preset, display layout and presentation mode) to Siri and Spotlight without
building a shortcut ("Next wallpaper in WallpaperMachine", "Random wallpaper in
WallpaperMachine", "Mute wallpapers with WallpaperMachine", "Apply a wallpaper with WallpaperMachine", "Toggle presentation mode in WallpaperMachine"). The actions run in the app's own process; if it is not running,
macOS starts it first.

**Apply Wallpaper** also has an **On all displays** option, off by default, that
applies the wallpaper to every enabled independent display instead of one; it wins
over a chosen **Display**.

**Random Wallpaper** also has a **Choose from** option, **All wallpapers** by default or
**Favorites**, and an optional **Collection** picker to narrow the pool.

## Read-only status file

`AutomationStatusWriter` (`App/Services/Automation/AutomationStatusWriter.swift`) writes an
event-driven, read-only JSON snapshot atomically to `status.json` inside `ClientPaths.supportURL`
(`~/Library/Application Support/WallpaperMachine/status.json`, or `$WALLPAPER_MACHINE_HOME/status.json`
when overridden). External tools such as Raycast, SketchyBar or Stream Deck can read this file
directly with no polling inside WallpaperMachine, no extra macOS permissions, no open sockets
and no standalone CLI binary. Disk writes occur only when active wallpapers, playback pause
state, global mute, presentation mode, desktop-widget visibility or favorite membership actually
changes.

**Previous Wallpaper**, **Next Wallpaper**, **Random Wallpaper**, **Apply Wallpaper** and **Apply Saved
Playlist** have an optional **Display** picker.
It lists connected, enabled independent displays using the same stable identities
as the panel; leaving it empty keeps the panel-target behavior. Execution checks
eligibility again, including when a queued command gets its turn. A disconnected
or mirrored target is rejected rather than silently redirected to another screen.
Property presets do not offer a display picker because wallpaper properties are
shared across displays. Presets whose wallpapers are no longer installed are not
offered; deletion between selection and execution is checked again.

## Links

`Info.plist` claims the `wallpapermachine` scheme (`CFBundleURLTypes`). The
command is the host, and `display`, `id`, `from`, `collection` and `page` are query values:

```
wallpapermachine://play
wallpapermachine://pause
wallpapermachine://toggle
wallpapermachine://mute
wallpapermachine://unmute
wallpapermachine://togglemute
wallpapermachine://previous
wallpapermachine://next
wallpapermachine://next?display=primary
wallpapermachine://random
wallpapermachine://random?display=primary&from=favorites
wallpapermachine://random?collection=Nature
wallpapermachine://apply?id=3632513108
wallpapermachine://apply?id=3632513108&display=all
wallpapermachine://playlist?id=PLAN_ID&display=primary
wallpapermachine://preset?id=PRESET_ID
wallpapermachine://layout?id=LAYOUT_ID
wallpapermachine://open?page=settings
```

`mute`, `unmute` and `togglemute` take no query at all, like `play`, `pause` and `toggle`:
there is no per-display or per-wallpaper mute link, and no link that sets a volume.
Desktop icons (which restart Finder), desktop widgets, presentation mode, volume and favorite
toggles are never exposed through `wallpapermachine://` links; use Shortcuts or global
keyboard shortcuts instead.

`display=all` is accepted by `apply` only and cannot be a display's own selector
(`primary`, a number or `identity:{…}`); `next`, `previous`, `random` and `playlist` treat it as
an unknown display and fail. `random` takes `from=all` (the default) or `from=favorites`, in
any case, and an optional `collection=` (collection id or name); any other value, or a name given twice, is refused rather than guessed at.

A link with an unknown command, a query value the command does not take, a value
given twice, or a path is ignored and logged rather than guessed at. A browser
asks before it opens the app. **Settings → Keyboard shortcuts → Shortcuts app and links**
lists the links. Plan and preset IDs are the IDs in their saved records, not their
display names; Shortcuts supplies name-based pickers without requiring these IDs.

## Verification

Link parsing and refusals, including that removing a wallpaper has no link, that the mute
links take nothing, and what `random` takes (`AutomationCommandTests`, which also checks the pools: favorites that left
the library and wallpapers held back after a crash are never offered), the menu bar's
layout (`StatusMenuModelTests`: the flat
menu for one display, Mute Wallpapers after Play/Pause, ticked while muted and offered then
with nothing playing, a submenu per display with every command naming its own display,
main display first then left to right, distinct titles, Remove becoming Start Again on
an empty display, Random Wallpaper after Next and left out where nothing else can be
chosen, ten recent entries with the current one ticked, and which displays
count), Random Wallpaper's round (`PlaylistStoreTests`) and its pick through the real
command queue (`WallpaperDisplayTransferIntegrationTests`: a round never repeats the
wallpaper on screen and shows each once, favorites only, a refused or failed pick
leaving the round alone, the pick made when the display's turn comes), waiting for the app and failures
reaching the caller (`AppAutomationTests`), hotkey preferences and the key-code and
modifier mapping (`HotKeyPreferencesTests`, `GlobalHotKeysTests`), the mute preference and how it
joins the audio suppression the bridge receives (`PlaybackPreferencesTests`,
`PlaybackPolicyCompositionTests`; the Settings switch is in `PanelPerformanceSettingsTests`), the planner, store and
scheduler (`WallpaperAutomationPlannerTests`, `WallpaperAutomationStoreTests`,
`WallpaperAutomationSchedulerTests`: weekday rules, simultaneous events, disabled rules
and legacy decoding without `isEnabled`, rule reordering with stale-drag validation,
appearance choices, DST, solar offsets crossing midnight, absent polar events, catch-up
and retry against a fake clock and the real command queue, manual precedence including
a rule giving way to a waiting or running manual command, Focus exit and
interrupted recovery), the panel's validation and queued manual playlist edits
(`PanelPlaylistActionsTests`), the rule actions, reordering, today's solar readout and
editor (`PanelAutomationActionsTests`, `DisplaysSettingsModelTests`,
`DisplaysSettingsDraftsTests`), the shortcut recorder
(`PanelHotKeyActionsTests`, `ShortcutsRecorderModelTests`), event-driven status JSON writes (`AutomationStatusWriterTests`), Presentation Mode save/restore and opt-in Finder icon guardrails (`PresentationModeControllerTests`), and
rule merging and rollback in backups (`WallpaperBackupTests`) each have their own suite;
the Space tests are listed in [Spaces verification](spaces.md#storage-and-verification).
The domain inventory is in [coverage](../testing/coverage.md).

These tests do not verify how the menu draws with two or more real displays, a real press
of a registered shortcut, the Shortcuts app, a link opened from a browser, actual Focus transitions, system appearance notifications,
Siri/Spotlight registration, visible panel layout, desktop playback, or that scene, video and
Web wallpapers really go silent and come back through an audio output (the tests stop at the
suppression the bridge receives).

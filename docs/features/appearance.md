# Appearance

**Settings → Appearance** styles the app's own interface. Wallpaper colors,
playback and display settings are untouched.

## Options

| Setting | Values | Notes |
| --- | --- | --- |
| Appearance | **System (Auto)**, **Light**, **Dark**, each shown as a picture of a window | System follows the macOS light/dark setting as it changes; the choice sets the app's appearance (`NSApp.appearance`), which the panel and every native window follow |
| Accent color | Nine macOS-style swatches and a color well, with the chosen hex value beside them | The well takes any color the swatches lack and saves once the color has settled for a moment. Colors buttons, links, selection and focus rings |
| Surface tone | **Neutral**, **Warm**, **Cool**, each shown as a picture of a window | Warms or cools the window background |
| Window style | **Solid**, **Liquid Glass**, each shown as a picture of a window | Chooses opaque surfaces or a translucent behind-window frosted glass backdrop |
| Window transparency | 0%–100% slider (default 50%) | Controls how much shows through the Liquid Glass window while keeping labels readable; disabled in Solid mode and stays opaque when macOS **Reduce Transparency** is enabled |
| App icon | **Minimal**, **Day**, **Night** | Changes the running Dock icon immediately and restores the choice at launch; Finder and the menu bar stay unchanged |
| Halloween look | **Halloween week**, **Always**, **Off**, each shown as a picture of a window | Halloween week (the default) wears the [Halloween look](#seasonal-looks) from October 24 to November 1; Always wears it all year; Off never |
| Christmas look | **Christmas week**, **Always**, **Off**, each shown as a picture of a window | Christmas week (the default) wears the [Christmas look](#seasonal-looks) from December 18 to December 26; Always wears it all year; Off never |

Accent shades adapt so text, buttons and focus rings stay readable against the
resolved background. `PanelTheme` (`App/Views/ControlPanel/Theme/`) derives them for
the resolved light or dark appearance: `AccentPalette` fits the accent's fills, links,
rings and label colour for contrast, and `SurfacePalette` gives the tone's backgrounds,
text and semantic colours. What lies over a picture (a tile's marks, its download or apply
status and the darkening under it, its check and heart) is dark and white in every tone, season
and appearance, since the picture under it can be any colour; a mark's trophy and heart are a
bright green and a light pink in every look, and only a favorite's switched-on heart button,
pink on a white disc, follows the appearance. The panel's root applies them to every view below it and
sets the accent as the tint, re-rendering when the stored accent or tone changes, when
the resolved appearance flips and when the language does. It reads the appearance
macOS resolved and never sets one itself; `AppDelegate` is the only writer of
`NSApp.appearance`.

## Seasonal looks

While a seasonal look (**Halloween** or **Christmas**) is on, the window wears it instead
of the person's own tone, accent and Dock icon; their choices are kept and come back when
it ends. `AppThemeStore` reads the seasonal choices against today (`Season.halloween.covers`,
October 24 to November 1; `Season.christmas.covers`, December 18 to December 26, by the local
calendar) and publishes the result as `season`. Choosing **Always** for one season returns
the other season from **Always** to its automatic week so only one seasonal look is forced
at a time. The store reads the date again when macOS posts `NSCalendarDayChanged`, at
midnight or on waking from a sleep that crossed one, so each look starts and ends while the
app runs; it does no timer or per-frame work.

- **Palettes.** `PanelTheme` takes the season's surfaces and accent: `SurfacePalette`
  has Halloween and Christmas columns beside the tones (Halloween: moonlit ink in the dark,
  candlelit parchment in the light, pumpkin orange `#ff7a1a`; Christmas: evergreen winter
  night in the dark, snow-lit pine mist in the light, holly crimson `#d9363e`) and
  `AccentPalette` fits each seasonal accent like any other. Light, dark, System, and Liquid
  Glass window style still follow their own choices.
- **Mark and Dock icon.** A seasonal emblem takes the gear's place: a jack-o'-lantern for
  Halloween and an evergreen tree crowned with a star for Christmas, in both the title bar's
  mark (`AppMark`) and in the Dock, where `AppDelegate` shows `AppThemeStore.dockIconName`
  (`AppIconHalloween` or `AppIconChristmas`). Settings › About and the first welcome page
  show the same icon.
- **Papercut horizon.** Every picture of a look is cut from two-ink Victorian papercut
  silhouettes (`Halloween…` and `Christmas…` image sets). `SeasonHorizon` stands them on
  rolling hills under a low moon (with bats for Halloween and Santa's sleigh with still
  winter stars for Christmas). Across the window, a band of it sits on the Now Playing bar,
  which turns the horizon's ink in either appearance so the hills rise from it; its contents
  take the look's dark palette, and its popovers the window's own. The horizon draws once
  per size: still images and a path, no animation.
- **Settings and empty states.** Settings › Appearance leads with the seasonal group under
  the active season's horizon at banner size, under a night sky, and locks the surface tone,
  accent and app icon rows it stands in for. The empty Library, and a Library or Workshop
  search or filters that match nothing, show a papercut cameo (Halloween: empty easel and
  cat; Christmas: holly easel and stag reindeer) in front of the moon instead of their
  symbol (`PanelEmptyState.seasonalArt`); an error keeps its symbol. Each seasonal row's
  cards in Settings carry its moon and hills.

## Window material

By default (**Solid**), the window's materials are the system's own. The window has a
full-size content view and the toolbar is the window's own. macOS 26 draws a band under the
see-through title bar for each column of a window, and draws it by what the column holds:
opaque grey over a column that does not start with a scroll view, a light wash over one that
does, its own dark band over the system inspector column. So the window has one column: the
page and the inspector beside it sit in one full-width scroll view that never scrolls
(`PageScrollHost` in `PanelDetail.swift`), and the bar is the page's colour under one wash
from the traffic lights to the window's edge. The inspector is a column of the page
(`InspectorColumn`), not `.inspector`. Laying a colour over the band from SwiftUI does not
reach it, and `NSWindow.titlebarAppearsTransparent` is never set because it sends a narrow
window whose scroll bars take room into an endless constraint pass. In Solid mode, the page
column paints the tone's opaque background (`SurfacePalette`) and adds no visual-effect view
or backdrop of its own.

When **Liquid Glass** is chosen, `ControlPanelWindow.applyWindowStyle` clears window opacity
(`isOpaque = false`, `backgroundColor = .clear`) and `WindowGlassBackdrop` places a
behind-window `NSVisualEffectView` (`.hudWindow`, `.behindWindow`) behind the window content,
tinted by the active theme's background colour. Secondary columns, cards, footers and the
Now Playing bar scale their surface opacity in `PanelTheme` from the **Window transparency**
slider (0%–100%), keeping a contrast floor so text and controls stay legible at 100%.
Dragging the slider previews live and saves on release. Under macOS **Reduce Transparency**,
both the window and every SwiftUI surface fall back automatically to opaque Solid fills.

## Persistence and reset

Choices are stored in the app's defaults (`AppThemeStore`, the
`WallpaperMachine.appTheme` default) and stay usable before the renderer's settings
arrive. Changes apply immediately and are remembered for the next launch. An invalid accent
(anything but `#rrggbb`) or out-of-range transparency (anything outside `0...100`) is
rejected without overwriting the saved value. **Reset appearance** restores System, the
default accent, the Neutral tone, Solid window, the Day icon and automatic seasonal weeks;
it does not touch wallpapers, playback or display configuration. Backups carry the seasonal
and Liquid Glass choices with the rest of the theme.

## App icon

The Dock picker is independent of the panel's light/dark theme. **Day** and **Night**
are the white-background and black-background variants of the bundled icon, which
macOS also selects for Finder through its *Appearance → Icon & widget style* setting;
neither the panel theme nor the Dock icon preference overrides that. **Minimal** uses
the same frame-and-gear mark in blue on white, without the gradient wallpaper fill. The
selection is applied with `NSApplication.applicationIconImage` from the
`AppIcon{Minimal,Day,Night}` image sets of `App/Resources/Assets.xcassets`, without
changing the app bundle or resetting system icon caches. Day is the default. The
selected icon applies while the app is running; a pinned Dock entry can show the
bundled icon after the app quits. The menu bar uses a monochrome template (`TrayIcon`),
and the panel shows the chosen icon's image on the first welcome page and at the top of
Settings → About.

## Brand assets

`scripts/brand.py` owns the mark's geometry and colours and documents its outputs in
its module docstring; the Manrope wordmark is stored as outlines in
`scripts/lib/wordmark.py`, so rendering needs no font installation. Regenerate the app
assets on macOS (it uses Quick Look, `sips`, and Xcode's Icon Composer and Swift) with:

```sh
python3 scripts/brand.py                           # app icon, Dock choices, tray icon, DMG background
python3 scripts/brand.py --seasonal                # only the seasonal Dock icons (Halloween, Christmas)
python3 scripts/brand.py --website <site-checkout> # plus logo, favicons and manifest there
```

- The app icon is generated as `App/Resources/AppIcon.icon`, an Icon Composer document
  of vector foreground layers plus solid light and dark backgrounds that Xcode compiles
  into the app's assets and fallback ICNS. macOS owns the outer mask, so no inset tile
  or opaque canvas is baked into the artwork. The mark is a filled outline (macOS 26
  recoloring fills an open stroked path despite `fill="none"`), and the panel meets the
  frame through an explicit curved cutout rather than an SVG mask so Icon Composer
  preserves the separation.
- The Dock exports, `{minimal,day,night}.png` inside the `AppIcon{Minimal,Day,Night}.imageset`
  folders of `App/Resources/Assets.xcassets`, are fixed-appearance 1024 px renders through
  Icon Composer with `--design-generation 26` (the deployment target's generation, not the
  newer preview default), keep a 100 px transparent outer margin and load as 512-point
  Retina images. The root README displays `day.png`; update its path there if the export
  is renamed.
- The seasonal Dock icons (`AppIconHalloween.imageset/halloween.png` and
  `AppIconChristmas.imageset/christmas.png`) are the Night tile with
  `Resources/Seasonal/halloween-night.jpg` or `christmas-night.jpg` (a papercut night
  composed from each season's silhouettes) clipped to the screen panel and the seasonal
  emblem (`PUMPKIN` or `CHRISTMAS` in `brand.py`, the same outlines as `AppMark`'s) in the
  gear's place, clear of the frame's ends as the gear is.
- The small-size mark is heavier and stays reserved for the menu bar; the panel shows the
  Dock icon images instead.
- Website export writes `brand/logo.svg` (light backgrounds), `brand/logo-dark.svg`,
  `brand/mark.svg`, `brand/app-icon-{minimal,day,night}.{svg,png}` (the unqualified
  `app-icon.*` is Day) and favicons, touch and manifest icons. Its PNGs are copied from
  those image sets to keep the native rendering; SVGs share the geometry and colors
  without Icon Composer's lighting. To refresh only the website from the current Dock
  PNGs, add `--skip-app`; after changing native icon geometry, run the regular
  `--website` command so both sets regenerate together.

## Verification

Appearance preferences, invalid-change rejection, reset isolation, the Settings
controls' saved format and the palettes derived from the preferences and the resolved
appearance are inventoried under *Appearance* and *Panel* in
[coverage](../testing/coverage.md). The materials, the rendering of the icon variants in
Finder and the Dock, and Reduce Transparency need a manual look
([manual smoke](../testing/manual-smoke.md#appearance)).

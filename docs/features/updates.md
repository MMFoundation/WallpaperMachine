# App updates

Official releases use Sparkle. WallpaperMachine can look for a new version by itself, but
downloading and restarting are choices you make. A locked Mac or a sleeping display is never
a reason to install an update. Steam Workshop wallpaper updates have their own setting and
schedule; changing one does not change the other.

## Checking for updates

Use **WallpaperMachine → Check for Updates…**, the menu bar, or **Settings → About**.
A manual check opens Sparkle’s native window and reports a new version, no update, or a
failure. If a version is already waiting, the menu names it and About offers **Show Update**.
The window lets you read its release notes before deciding whether to download.

### Automatic updates

**Check for updates automatically** is on by default and can be turned off in the first-run
guide or in About. The app checks on launch if its last check was at least 4½ hours ago, then
about every six hours using the macOS background activity scheduler. A scheduled check asks
Sparkle only for update information: it neither downloads the archive nor opens an installer.
All three old update modes checked automatically; their download and unattended-install
behavior is not carried forward.

A verified newer build stays in the menu and About across launches. Returning to the active
control panel can show a reminder after onboarding, when no sheet, modal dialog or feature
introduction is in the way. **Remind Me Tomorrow** keeps the menu entry and postpones the
reminder for 24 hours. **Skip This Version** hides that version but not the next one; a
manual Sparkle check can still offer a skipped version. Installing the build or receiving a
verified check with no eligible update clears the pending notice. A network failure does not.

### What a check reads

The primary feed is `https://www.wallpapermachine.app/updates/appcast`. The website streams
the signed `appcast.xml` from the latest **MMFoundation/WallpaperMachine** GitHub release
without changing its bytes. On a transport failure the app retries the same kind of check
once against GitHub directly. Offline, cancellation, parsing or signature errors are not
retried through another source. There is no GitHub REST request or third-party download proxy.
A manual transport failure can require dismissing Sparkle’s error dialog before the retry.

## Downloading

The signed feed identifies the version, build and official GitHub ZIP. The normal download
streams through `/updates/download/v<version>/WallpaperMachine-<version>-arm64.zip` on the
same website; the direct fallback uses the original GitHub release URL. Sparkle checks the
feed signature with WallpaperMachine’s own Ed25519 public key and verifies the archive
before extraction. A prolonged outage never enables unsigned feeds. A retry does not skip
verification or approve a download on your behalf.

## Installing

Sparkle stages the verified app and offers to install and relaunch. WallpaperMachine’s
normal quit sequence still tries to restore the desktop, but restoration failure does not
block installation. The new version keeps the original wallpaper records: with desktop
picture writing off it retries at launch; with writing on it resumes posters and restores
the originals at a later quit ([desktop recovery](desktop-picture.md#updates)). Updating does not replace the wallpaper
library or settings. The app does not run a shell script to replace itself. Local Debug
builds have no production feed, and an app without a release public key or in the immutable
Nix store does not start an updater. Update Nix-managed copies through Nix.

For Macs still running the old updater, each new release also ships the original DMG,
checksum and `WallpaperMachine-update.json`. Those copies can install the first Sparkle
release by the path they already know. New copies never fall back to that unsigned manifest.
See the [publication contract](../release.md#what-the-in-app-updater-expects).

## The update window

The offer, download progress, cancellation, errors and restart controls are Sparkle’s
windows. About shows the most recent release notes from the changelog bundled with the
installed app (up to 20 versions), so they remain available offline. It uses the existing
English, Simplified Chinese and Korean entries and falls back to English where needed.
After an observed version upgrade, an onboarded user sees About once, unless a file was
opened on launch or a feature introduction takes precedence. A first install and an
ordinary relaunch do not open the notes.

### Feature introductions

A release can introduce a feature in a separate window. The first version after 1.10.0,
for example, introduced desktop widgets. `FeatureIntroductionStore` records the newest
version launched and the introductions already shown. The window appears only for an
existing user who crossed a feature’s introduction version, not on every software update.

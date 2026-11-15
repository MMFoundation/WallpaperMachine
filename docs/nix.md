# Nix installation and configuration

The flake packages the official, signed WallpaperMachine release for Apple
silicon Macs running macOS 15 or later. It extracts the release DMG and keeps
the application bundle intact, including its lock-screen extension. It does
not compile the source in your checkout or require Xcode.

The package version and download hash live in [../nix/package.nix](../nix/package.nix).
The package is independent of whether nixpkgs includes WallpaperMachine.

## Add the input

Add this input to your existing flake:

```nix
inputs.wallpapermachine = {
  url = "github:MMFoundation/WallpaperMachine";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

For an unmerged fork, use `github:OWNER/WallpaperMachine/BRANCH` as the URL.

Use either the Home Manager module or the nix-darwin module for a given user.
Both expose `programs.wallpapermachine` and default to this repository's package.
No overlay is required.

## Home Manager

Add the module to your existing `homeManagerConfiguration`:

```nix
home-manager.lib.homeManagerConfiguration {
  pkgs = nixpkgs.legacyPackages.aarch64-darwin;
  modules = [
    inputs.wallpapermachine.homeManagerModules.default
    {
      home.username = "alice";
      home.homeDirectory = "/Users/alice";
      home.stateVersion = "26.05";

      programs.wallpapermachine = {
        enable = true;
        launchd.enable = true;
        settings = {
          "WallpaperMachine.lowPowerModeAction" = "reduceQuality";
          "WallpaperMachine.otherAudioAction" = "mute";
          "WallpaperMachine.lowBatteryThreshold" = 20;
        };
      };
    }
  ];
}
```

Use your own username, home directory and existing `home.stateVersion`. If you
use Home Manager inside nix-darwin, put the module in
`home-manager.sharedModules` or your user's `imports`, and set
`programs.wallpapermachine` inside that user's Home Manager configuration.

The module installs the app through `home.packages`. Its activation script
writes each preference separately with `defaults write`, preserving unrelated
preferences managed by the app.

## nix-darwin

Add the module to your existing `darwinSystem`:

```nix
nix-darwin.lib.darwinSystem {
  modules = [
    inputs.wallpapermachine.darwinModules.default
    {
      nixpkgs.hostPlatform = "aarch64-darwin";
      system.primaryUser = "alice";

      programs.wallpapermachine = {
        enable = true;
        launchd.enable = true;
        settings."WallpaperMachine.lowPowerModeAction" = "reduceQuality";
      };
    }
    # Keep the rest of your existing system modules here.
  ];
}
```

The module installs the app through `environment.systemPackages`. Preferences
and the optional user launch agent apply to `system.primaryUser`.

## Options

| Option | Default | Behavior |
|---|---|---|
| `programs.wallpapermachine.enable` | `false` | Install the app and apply preferences |
| `programs.wallpapermachine.package` | Package from this repository | Override the application derivation |
| `programs.wallpapermachine.launchd.enable` | `false` | Start at login without opening the panel after onboarding |
| `programs.wallpapermachine.settings` | Update mode `notify` | Set preferences in the `app.wallpapermachine` domain |

Settings use literal UserDefaults keys, including their `WallpaperMachine.`
prefix. The module validates playback actions, volume, battery thresholds and
inactivity intervals against the values the app supports. Other keys accept
strings, booleans, integers, floats, lists and dictionaries. For example:

```nix
programs.wallpapermachine.settings = {
  "WallpaperMachine.displaySleepAction" = "stop";
  "WallpaperMachine.otherAudioVolume" = 30;
  "WallpaperMachine.inactivityAction" = "pause";
  "WallpaperMachine.inactivityMinutes" = 10;
  "WallpaperMachine.playOnlyOnActiveDisplay" = true;
  "WallpaperMachine.hideAfterActivating" = true;
};
```

Quit WallpaperMachine before activation and reopen it afterwards to reload preferences.
Removing a setting, or setting a documented optional preference to `null`,
leaves its existing macOS value in place. Values changed in the app can be
reapplied by your next Nix activation. Wallpaper library data, credentials,
and macOS permission grants remain under the app's and macOS's control.

The module defaults `WallpaperMachine.updates.mode` to `notify` so the app does
not automatically replace a version managed by Nix. Update the release version
and hash in `nix/package.nix` to package a new app release, then update your
flake input. Updating `flake.lock` alone only updates Nix dependencies.

When enabling the launch agent, disable the app's own **Launch at login**
setting. The agent does not restart an app you quit. Activating a launch agent
can start the app immediately as well as at the next login.

## Package without a module

From a checkout on an Apple silicon Mac:

```sh
nix build .#
```

The application is at `result/Applications/WallpaperMachine.app`.
The optional `overlays.default` output adds `pkgs.wallpapermachine` to your own
package set. The package is also exported as
`packages.aarch64-darwin.wallpapermachine`.

## Verification

```sh
nix flake check --print-build-logs
nix fmt -- --check flake.nix nix/*.nix
```

Checks evaluate both modules using real Home Manager and nix-darwin inputs,
including package overrides, generated preferences, launch agents, disabled
modules and invalid settings. They also repack the actual release DMG and
inspect the app's version, bundle identifiers, architecture and extension.
Home Manager and nix-darwin are flake inputs for those integration checks;
the exported modules use the consumer's module system and package set.

Linux can perform these checks without running the app. On Apple silicon
macOS, the package also runs `codesign --verify --deep --strict` against the
installed bundle. Linux checks cannot establish macOS signature acceptance,
permission behavior, wallpaper playback or lock-screen extension registration.

The Nix integration does not provide a development shell for compiling the
native app. See [build.md](build.md) for the Xcode build environment.

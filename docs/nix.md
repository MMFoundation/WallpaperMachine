# Nix installation and configuration

The flake packages the official, signed WallpaperMachine release for Apple
silicon Macs running macOS 15 or later. It extracts the release DMG and keeps
the application bundle intact, including its lock-screen extension. It does
not compile the source in your checkout or require Xcode. The animated lock
screen requires macOS 26 or later.

The package version and download hash live in [../nix/package.nix](../nix/package.nix).
The package is independent of whether nixpkgs includes WallpaperMachine.

## Add the input

Add this input to your existing flake's `inputs` attribute set:

```nix
wallpapermachine = {
  url = "github:MMFoundation/WallpaperMachine";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Before this change is merged upstream, use
`github:NikoPit/WallpaperMachine/nix-support` as the URL. Include
`wallpapermachine` in your `outputs` arguments or capture all inputs with
`outputs = inputs: ...` so your configuration can access it.

The flake exports a Home Manager module. The module defaults to the package
from this repository, so it needs no overlay or nixpkgs package contribution.

## Standalone Home Manager

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
          updates.mode = "notify";
          playback = {
            lowPowerModeAction = "reduceQuality";
            otherAudioAction = "mute";
            lowBatteryThreshold = 20;
          };
        };
      };
    }
  ];
}
```

Use your own username, home directory and existing `home.stateVersion`. The
example assumes `nixpkgs` and `home-manager` are already flake inputs and in
scope. Apply the configuration with your usual Home Manager activation command.

The module installs the app through `home.packages`. Its activation script
writes each configured preference separately with `defaults write`, preserving
unrelated preferences managed by the app.

## Home Manager inside nix-darwin

Use the same module inside your existing Home Manager integration. Add the
following to a nix-darwin configuration module where `inputs` is in scope:

```nix
{
  home-manager.sharedModules = [
    inputs.wallpapermachine.homeManagerModules.default
  ];

  home-manager.users.alice.programs.wallpapermachine = {
    enable = true;
    launchd.enable = true;
    settings.playback.lowPowerModeAction = "reduceQuality";
  };
}
```

Replace `alice` with your Home Manager user. This assumes your `darwinSystem`
already imports `home-manager.darwinModules.home-manager`. Apply the
configuration with your usual `darwin-rebuild switch` command. There is no
separate WallpaperMachine nix-darwin module.

## Options

All options below are under `programs.wallpapermachine`.

| Option | Default | Behavior |
|---|---|---|
| `enable` | `false` | Install the app and apply preferences |
| `package` | Package from this repository | Override the application derivation |
| `launchd.enable` | `false` | Start at login without opening the panel after onboarding |
| `settings.updates.mode` | `"notify"` | Choose `notify`, `download` or `automatic` updates |
| `settings.playback.*` | `null` | Configure playback actions, volume, battery thresholds, inactivity and mute |
| `settings.desktopPicture.enable` | `null` | Write wallpaper snapshots as the macOS desktop picture |
| `settings.desktopPicture.refreshPeriodically` | `null` | Refresh the macOS desktop picture periodically |
| `extraSettings` | `{ }` | Write additional preferences using literal UserDefaults keys |

Named settings have descriptions and validate the values the app supports.
For example, `settings.playback.otherAudioVolume` accepts integers between 0
and 100, and `settings.playback.lowBatteryThreshold` accepts 10, 20 or 30.
See [../nix/options.nix](../nix/options.nix) for every option and its description.

Use `extraSettings` for preferences without a named option:

```nix
{
  programs.wallpapermachine = {
    enable = true;
    settings = {
      playback.displaySleepAction = "stop";
      playback.otherAudioVolume = 30;
      desktopPicture.enable = false;
    };
    extraSettings."WallpaperMachine.hideAfterActivating" = true;
  };
}
```

`extraSettings` accepts property-list strings, booleans, numbers, lists and
dictionaries. It overrides named settings that map to the same preference key.
The mapping lives in [../nix/preferences.nix](../nix/preferences.nix).

Quit WallpaperMachine before activation and reopen it afterwards to reload
preferences. Removing a preference, or setting a named optional preference to
`null`, leaves its existing macOS value in place. Your next Nix activation
reapplies configured values that you changed in the app. The app manages its
wallpaper library and credentials; macOS manages its permission grants.

The update mode defaults to `notify` so the app does not automatically replace
a version managed by Nix. To package a new app release, update the version and
hash in `nix/package.nix`. Users then update their WallpaperMachine flake input
and activate their configuration. Updating this repository's `flake.lock`
alone only updates Nix dependencies.

When enabling the launch agent, disable the app's own Launch at login setting.
The agent does not restart an app you quit. Activating a launch agent can start
the app immediately as well as at the next login. An unfinished welcome guide
or startup failure can still open the panel.

## Package without Home Manager

From a checkout on an Apple silicon Mac:

```sh
nix build .#
```

The application is at `result/Applications/WallpaperMachine.app`. To build from
the fork directly, use `nix build github:NikoPit/WallpaperMachine/nix-support`.
Building creates the bundle in the Nix store; add the package to your system
configuration to install it through nix-darwin.

The package is exported as `packages.aarch64-darwin.default` and
`packages.aarch64-darwin.wallpapermachine`. The optional `overlays.default`
output adds `pkgs.wallpapermachine` to your own package set.

## Verification

Run these commands from the repository checkout:

```sh
nix flake check --print-build-logs
nix flake check --all-systems --no-build
nix fmt -- --check flake.nix nix/*.nix
```

Checks evaluate the module using real Home Manager inputs, both standalone
and inside nix-darwin. They cover preference mappings, package overrides,
serialized preferences, launch agents, disabled configurations, invalid
settings and `extraSettings` precedence. They also repack the actual release
DMG and inspect its version, bundle identifiers, architecture and extension.
Home Manager and nix-darwin are flake inputs for these integration checks;
the exported module uses the consumer's Home Manager and package set.

Linux can perform these checks without running the app. The second command
evaluates all exported systems but does not build them. On Apple silicon
macOS, the package also runs `codesign --verify --deep --strict` against the
installed bundle.

The current checks passed on Linux. macOS signature verification, activation,
wallpaper playback and lock-screen extension registration have not been
verified. The native test gate passed its Python stage but stopped at the
missing XcodeGen tool on Linux. It did not pass the full native gate.

The flake does not provide a development shell for compiling the native app.
See [build.md](build.md) for the Xcode build environment.

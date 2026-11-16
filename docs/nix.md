# Nix installation and configuration

WallpaperMachine supports Apple silicon Macs running macOS 15 or later.
The animated lock screen requires macOS 26 or later.

## Add the input

Add WallpaperMachine to your flake's `inputs`:

```nix
wallpapermachine = {
  url = "github:MMFoundation/WallpaperMachine";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

## Standalone Home Manager

Add `inputs.wallpapermachine.homeManagerModules.default` to your Home Manager
`modules` list. Then configure the app in your Home Manager configuration:

```nix
{
  programs.wallpapermachine = {
    enable = true;
    # Start WallpaperMachine when you log in.
    launchd.enable = true;
    settings = {
      # Let Nix control app updates by default.
      updates.mode = "notify";
      playback = {
        # Lower wallpaper quality while macOS is in Low Power Mode.
        lowPowerModeAction = "reduceQuality";
        # Mute wallpapers while another app plays audio.
        otherAudioAction = "mute";
        # Apply the low-battery action at 20 percent.
        lowBatteryThreshold = 20;
      };
    };
  };
}
```

The settings in this example are optional. Choose only the ones you want to
configure, and replace the example values as needed. You can omit `settings`
entirely. Quit WallpaperMachine, activate your Home Manager configuration,
then reopen it to apply the preferences.

## Home Manager inside nix-darwin

Add the module to your existing Home Manager integration:

```nix
{
  home-manager.sharedModules = [
    inputs.wallpapermachine.homeManagerModules.default
  ];
}
```

Use the configuration example above in your user's Home Manager configuration.
Apply it with your usual `darwin-rebuild switch` command.

## Options

All options below are under `programs.wallpapermachine`.

| Option | Default | Behavior |
|---|---|---|
| `enable` | `false` | Install the app and apply preferences |
| `package` | Package from this repository | Choose a different application package |
| `launchd.enable` | `false` | Start at login without opening the panel after onboarding |
| `settings.updates.mode` | `"notify"` | Choose `notify`, `download` or `automatic` updates |
| `settings.playback.*` | `null` | Configure playback actions, volume, battery thresholds, inactivity and mute |
| `settings.desktopPicture.enable` | `null` | Write wallpaper snapshots as the macOS desktop picture |
| `settings.desktopPicture.refreshPeriodically` | `null` | Refresh the macOS desktop picture periodically |
| `extraSettings` | `{ }` | Set additional preferences using their original names |

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

`extraSettings` accepts strings, booleans, numbers, lists and dictionaries.
It overrides named settings that configure the same preference.

Removing a preference, or setting an optional preference to `null`, leaves its
existing value in place. Your next Nix activation reapplies configured values
that you changed in the app.

The update mode defaults to `notify` so Nix controls application updates.
To update WallpaperMachine, update its flake input and activate your
configuration.

When enabling `launchd.enable`, disable the app's own Launch at login setting.
The app can start immediately when you activate the configuration. Quitting it
keeps it closed until you reopen it or log in again. An unfinished welcome
guide or startup failure can still open the panel.

## Install without Home Manager

Add the package to your nix-darwin configuration:

```nix
{
  environment.systemPackages = [
    inputs.wallpapermachine.packages.aarch64-darwin.default
  ];
}
```

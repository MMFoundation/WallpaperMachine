{ lib, pkgs }:

let
  inherit (lib) mkOption types;

  # UserDefaults supports property lists. Reject functions, derivations and null
  # inside freeform values before the defaults writer tries to serialize them.
  plistValue =
    (types.oneOf [
      types.bool
      types.int
      types.float
      types.str
      (types.listOf plistValue)
      (types.attrsOf plistValue)
    ])
    // {
      description = "property-list value";
    };

  optionalSetting =
    type: description:
    mkOption {
      type = types.nullOr type;
      default = null;
      inherit description;
    };

  conditionAction = types.enum [
    "keepRunning"
    "reduceQuality"
    "pause"
    "stop"
  ];
in
{
  enable = lib.mkEnableOption "WallpaperMachine";

  package = mkOption {
    type = types.package;
    default = pkgs.callPackage ./package.nix { };
    defaultText = lib.literalExpression "pkgs.callPackage ./nix/package.nix { }";
    description = "WallpaperMachine application package, supplied by this flake by default.";
  };

  launchd.enable = lib.mkEnableOption ''
    starting WallpaperMachine at login through launchd. Disable the application's
    own Launch at login setting when using this option. Quitting the app does
    not restart it. The control panel stays closed after onboarding
  '';

  settings = mkOption {
    default = { };
    type = types.submodule {
      freeformType = types.attrsOf plistValue;
      options = {
        "WallpaperMachine.updates.mode" = mkOption {
          type = types.enum [
            "notify"
            "download"
            "automatic"
          ];
          default = "notify";
          description = ''
            Built-in update behavior. Defaults to notifications so Nix controls
            which application version is installed.
          '';
        };
        "WallpaperMachine.displaySleepAction" = optionalSetting (types.enum [
          "pause"
          "stop"
        ]) "Playback action when a display sleeps.";
        "WallpaperMachine.otherAudioAction" = optionalSetting (types.enum [
          "keepRunning"
          "reduceVolume"
          "mute"
          "pause"
        ]) "Playback action while another application plays audio.";
        "WallpaperMachine.otherAudioVolume" =
          optionalSetting (types.ints.between 0 100) "Percentage of wallpaper volume used by the reduceVolume action.";
        "WallpaperMachine.otherAppInFrontAction" = optionalSetting (types.enum [
          "keepRunning"
          "mute"
          "pause"
          "pauseOnBattery"
        ]) "Playback action while another application is in front.";
        "WallpaperMachine.desktopCoveredAction" = optionalSetting (types.enum [
          "pause"
          "mute"
          "reduceVolume"
          "keepRunning"
        ]) "Playback action when other windows cover the desktop.";
        "WallpaperMachine.lowPowerModeAction" =
          optionalSetting conditionAction "Playback action while Low Power Mode is active.";
        "WallpaperMachine.thermalAction" =
          optionalSetting conditionAction "Playback action when macOS reports serious or critical thermal pressure.";
        "WallpaperMachine.lowBatteryAction" =
          optionalSetting conditionAction "Playback action while the battery is at or below the configured threshold.";
        "WallpaperMachine.lowBatteryThreshold" = optionalSetting (types.enum [
          10
          20
          30
        ]) "Low battery threshold as a percentage.";
        "WallpaperMachine.inactivityAction" = optionalSetting (types.enum [
          "keepRunning"
          "pause"
          "stop"
        ]) "Playback action after the configured period without user input.";
        "WallpaperMachine.inactivityMinutes" = optionalSetting (types.enum [
          5
          10
          15
          30
          60
        ]) "Minutes without input before applying the inactivity action.";
        "WallpaperMachine.playOnlyOnActiveDisplay" =
          optionalSetting types.bool "Whether to play wallpapers only on the display containing the pointer.";
        "WallpaperMachine.wallpapersMuted" = optionalSetting types.bool "Whether to mute every wallpaper.";
        "WallpaperMachine.writeDesktopPicture" =
          optionalSetting types.bool "Whether to write wallpaper snapshots as the macOS desktop picture.";
        "WallpaperMachine.refreshDesktopPicturePeriodically" =
          optionalSetting types.bool "Whether to refresh the macOS desktop picture periodically.";
      };
    };
    example = {
      "WallpaperMachine.lowPowerModeAction" = "reduceQuality";
      "WallpaperMachine.otherAudioAction" = "mute";
    };
    description = ''
      Preferences in the app.wallpapermachine UserDefaults domain, using literal
      preference keys. Null values for the documented settings leave those
      preferences unmanaged. Other keys accept property-list values.

      Quit WallpaperMachine before activation and reopen it afterwards to reload preferences.
      Removing a setting does not remove the value previously written to macOS.
      Wallpaper library data and Steam credentials are managed by the app.
    '';
  };
}

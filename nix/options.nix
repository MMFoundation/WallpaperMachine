{ lib, pkgs }:

let
  inherit (lib) mkOption types;

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

  optionalPreference =
    type: description:
    mkOption {
      type = types.nullOr type;
      default = null;
      description = description + " A null value leaves the existing preference unmanaged.";
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

  settings = {
    updates.mode = mkOption {
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

    playback = {
      displaySleepAction = optionalPreference (types.enum [
        "pause"
        "stop"
      ]) "Playback action when a display sleeps.";
      otherAudioAction = optionalPreference (types.enum [
        "keepRunning"
        "reduceVolume"
        "mute"
        "pause"
      ]) "Playback action while another application plays audio.";
      otherAudioVolume = optionalPreference (types.ints.between 0 100) "Percentage of wallpaper volume used by the reduceVolume action.";
      otherAppInFrontAction = optionalPreference (types.enum [
        "keepRunning"
        "mute"
        "pause"
        "pauseOnBattery"
      ]) "Playback action while another application is in front.";
      desktopCoveredAction = optionalPreference (types.enum [
        "pause"
        "mute"
        "reduceVolume"
        "keepRunning"
      ]) "Playback action when other windows cover the desktop.";
      lowPowerModeAction = optionalPreference conditionAction "Playback action while Low Power Mode is active.";
      thermalAction = optionalPreference conditionAction "Playback action when macOS reports serious or critical thermal pressure.";
      lowBatteryAction = optionalPreference conditionAction "Playback action while the battery is at or below the configured threshold.";
      lowBatteryThreshold = optionalPreference (types.enum [
        10
        20
        30
      ]) "Low battery threshold as a percentage.";
      inactivityAction = optionalPreference (types.enum [
        "keepRunning"
        "pause"
        "stop"
      ]) "Playback action after the configured period without user input.";
      inactivityMinutes = optionalPreference (types.enum [
        5
        10
        15
        30
        60
      ]) "Minutes without input before applying the inactivity action.";
      playOnlyOnActiveDisplay = optionalPreference types.bool "Whether to play wallpapers only on the display containing the pointer.";
      muted = optionalPreference types.bool "Whether to mute every wallpaper.";
    };

    desktopPicture = {
      enable = optionalPreference types.bool "Whether to write wallpaper snapshots as the macOS desktop picture.";
      refreshPeriodically = optionalPreference types.bool "Whether to refresh the macOS desktop picture periodically.";
    };
  };

  extraSettings = mkOption {
    type = types.attrsOf plistValue;
    default = { };
    example = {
      "WallpaperMachine.hideAfterActivating" = true;
    };
    description = ''
      Additional preferences in the app.wallpapermachine UserDefaults domain,
      using literal preference keys. Values here override the named options
      when both configure the same preference. Values must be property-list
      strings, booleans, numbers, lists or dictionaries.

      Quit WallpaperMachine before activation and reopen it afterwards to reload
      preferences. Removing a preference leaves its existing macOS value in
      place. Wallpaper library data and Steam credentials are managed by the app.
    '';
  };
}

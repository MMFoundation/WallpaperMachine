{ lib, config }:

lib.filterAttrs (_: value: value != null) {
  "WallpaperMachine.updates.mode" = config.settings.updates.mode;
  "WallpaperMachine.displaySleepAction" = config.settings.playback.displaySleepAction;
  "WallpaperMachine.otherAudioAction" = config.settings.playback.otherAudioAction;
  "WallpaperMachine.otherAudioVolume" = config.settings.playback.otherAudioVolume;
  "WallpaperMachine.otherAppInFrontAction" = config.settings.playback.otherAppInFrontAction;
  "WallpaperMachine.desktopCoveredAction" = config.settings.playback.desktopCoveredAction;
  "WallpaperMachine.lowPowerModeAction" = config.settings.playback.lowPowerModeAction;
  "WallpaperMachine.thermalAction" = config.settings.playback.thermalAction;
  "WallpaperMachine.lowBatteryAction" = config.settings.playback.lowBatteryAction;
  "WallpaperMachine.lowBatteryThreshold" = config.settings.playback.lowBatteryThreshold;
  "WallpaperMachine.inactivityAction" = config.settings.playback.inactivityAction;
  "WallpaperMachine.inactivityMinutes" = config.settings.playback.inactivityMinutes;
  "WallpaperMachine.playOnlyOnActiveDisplay" = config.settings.playback.playOnlyOnActiveDisplay;
  "WallpaperMachine.wallpapersMuted" = config.settings.playback.muted;
  "WallpaperMachine.writeDesktopPicture" = config.settings.desktopPicture.enable;
  "WallpaperMachine.refreshDesktopPicturePeriodically" =
    config.settings.desktopPicture.refreshPeriodically;
}
// config.extraSettings

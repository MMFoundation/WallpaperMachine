{ lib, config }:

lib.filterAttrs (_: value: value != null) {
  "WallpaperMachine.updates.mode" = config.updates.mode;
  "WallpaperMachine.displaySleepAction" = config.playback.displaySleepAction;
  "WallpaperMachine.otherAudioAction" = config.playback.otherAudioAction;
  "WallpaperMachine.otherAudioVolume" = config.playback.otherAudioVolume;
  "WallpaperMachine.otherAppInFrontAction" = config.playback.otherAppInFrontAction;
  "WallpaperMachine.desktopCoveredAction" = config.playback.desktopCoveredAction;
  "WallpaperMachine.lowPowerModeAction" = config.playback.lowPowerModeAction;
  "WallpaperMachine.thermalAction" = config.playback.thermalAction;
  "WallpaperMachine.lowBatteryAction" = config.playback.lowBatteryAction;
  "WallpaperMachine.lowBatteryThreshold" = config.playback.lowBatteryThreshold;
  "WallpaperMachine.inactivityAction" = config.playback.inactivityAction;
  "WallpaperMachine.inactivityMinutes" = config.playback.inactivityMinutes;
  "WallpaperMachine.playOnlyOnActiveDisplay" = config.playback.playOnlyOnActiveDisplay;
  "WallpaperMachine.wallpapersMuted" = config.playback.muted;
  "WallpaperMachine.writeDesktopPicture" = config.desktopPicture.enable;
  "WallpaperMachine.refreshDesktopPicturePeriodically" = config.desktopPicture.refreshPeriodically;
}
// config.extraSettings

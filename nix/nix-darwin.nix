{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.wallpapermachine;
in
{
  options.programs.wallpapermachine = import ./options.nix { inherit lib pkgs; };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "aarch64-darwin";
        message = "WallpaperMachine requires Apple silicon and macOS 15 or later.";
      }
    ];

    environment.systemPackages = [ cfg.package ];
    system.defaults.CustomUserPreferences."app.wallpapermachine" = lib.filterAttrs (
      _: value: value != null
    ) cfg.settings;

    launchd.user.agents.wallpapermachine = lib.mkIf cfg.launchd.enable {
      serviceConfig = {
        ProgramArguments = [
          "${cfg.package}/Applications/WallpaperMachine.app/Contents/MacOS/WallpaperMachine"
        ];
        EnvironmentVariables.WALLPAPER_MACHINE_PANEL_AT_LAUNCH = "0";
        RunAtLoad = true;
        KeepAlive = false;
        LimitLoadToSessionType = "Aqua";
        ProcessType = "Interactive";
      };
    };
  };
}

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.wallpapermachine;
  settings = import ./preferences.nix {
    inherit lib;
    config = cfg;
  };
  appDirectory =
    if config.targets.darwin.copyApps.enable then
      "${config.home.homeDirectory}/${config.targets.darwin.copyApps.directory}"
    else
      "${cfg.package}/Applications";

  writePreference = key: value: ''
    run /usr/bin/defaults write app.wallpapermachine ${lib.escapeShellArg key} ${
      lib.escapeShellArg (lib.generators.toPlist { escape = true; } value)
    }
  '';
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

    home.packages = [ cfg.package ];
    # Write individual keys so app-managed preferences remain in the domain.
    home.activation.wallpapermachine = lib.hm.dag.entryBetween [ "setupLaunchAgents" ] (
      [ "writeBoundary" ]
      ++ lib.optional (cfg.launchd.enable && config.targets.darwin.copyApps.enable) "copyApps"
    ) (lib.concatStrings (lib.mapAttrsToList writePreference settings));

    launchd.agents.wallpapermachine = lib.mkIf cfg.launchd.enable {
      enable = true;
      config = {
        ProgramArguments = [
          "${appDirectory}/WallpaperMachine.app/Contents/MacOS/WallpaperMachine"
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

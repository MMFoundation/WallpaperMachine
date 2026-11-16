{ inputs, pkgs }:

let
  inherit (pkgs) lib;
  darwinPkgs = import inputs.nixpkgs { system = "aarch64-darwin"; };
  testPackage = darwinPkgs.emptyDirectory;

  home =
    {
      preferences ? { },
      enable ? true,
      launchd ? false,
      package ? testPackage,
      hostPkgs ? darwinPkgs,
      darwinOptions ? { },
    }:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = hostPkgs;
      modules = [
        inputs.self.homeManagerModules.default
        {
          home.username = "nix-test";
          home.homeDirectory = "/Users/nix-test";
          home.stateVersion = "26.05";
          targets.darwin = darwinOptions;
          programs.wallpapermachine = {
            inherit enable package;
            launchd.enable = launchd;
            settings = builtins.removeAttrs preferences [ "extraSettings" ];
            extraSettings = preferences.extraSettings or { };
          };
        }
      ];
    };

  darwin =
    {
      preferences ? { },
      enable ? true,
      launchd ? false,
    }:
    inputs.nix-darwin.lib.darwinSystem {
      modules = [
        inputs.home-manager.darwinModules.home-manager
        {
          nixpkgs.hostPlatform = "aarch64-darwin";
          system.stateVersion = 6;
          system.primaryUser = "nix-test";
          users.users.nix-test.home = "/Users/nix-test";
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            sharedModules = [ inputs.self.homeManagerModules.default ];
            users.nix-test = {
              home.stateVersion = "26.05";
              programs.wallpapermachine = {
                inherit enable;
                package = testPackage;
                launchd.enable = launchd;
                settings = builtins.removeAttrs preferences [ "extraSettings" ];
                extraSettings = preferences.extraSettings or { };
              };
            };
          };
        }
      ];
    };

  preferences = {
    updates.mode = "download";
    playback = {
      displaySleepAction = "stop";
      otherAudioAction = "reduceVolume";
      otherAudioVolume = 30;
      otherAppInFrontAction = "pauseOnBattery";
      desktopCoveredAction = "mute";
      lowPowerModeAction = "reduceQuality";
      thermalAction = "pause";
      lowBatteryAction = "stop";
      lowBatteryThreshold = 20;
      inactivityAction = "pause";
      inactivityMinutes = 10;
      playOnlyOnActiveDisplay = true;
      muted = false;
    };
    desktopPicture = {
      enable = false;
      refreshPeriodically = true;
    };
    extraSettings."Example.extra" = {
      text = "a'b<&>";
      values = [
        1
        0.5
        false
        "value"
      ];
    };
  };

  expected = {
    "WallpaperMachine.updates.mode" = "download";
    "WallpaperMachine.displaySleepAction" = "stop";
    "WallpaperMachine.otherAudioAction" = "reduceVolume";
    "WallpaperMachine.otherAudioVolume" = 30;
    "WallpaperMachine.otherAppInFrontAction" = "pauseOnBattery";
    "WallpaperMachine.desktopCoveredAction" = "mute";
    "WallpaperMachine.lowPowerModeAction" = "reduceQuality";
    "WallpaperMachine.thermalAction" = "pause";
    "WallpaperMachine.lowBatteryAction" = "stop";
    "WallpaperMachine.lowBatteryThreshold" = 20;
    "WallpaperMachine.inactivityAction" = "pause";
    "WallpaperMachine.inactivityMinutes" = 10;
    "WallpaperMachine.playOnlyOnActiveDisplay" = true;
    "WallpaperMachine.wallpapersMuted" = false;
    "WallpaperMachine.writeDesktopPicture" = false;
    "WallpaperMachine.refreshDesktopPicturePeriodically" = true;
    "Example.extra" = {
      text = "a'b<&>";
      values = [
        1
        0.5
        false
        "value"
      ];
    };
  };

  hm =
    (home {
      inherit preferences;
      launchd = true;
    }).config;
  nd =
    (darwin {
      inherit preferences;
      launchd = true;
    }).config;
  hmDisabled =
    (home {
      enable = false;
      hostPkgs = pkgs;
    }).config;
  ndDisabled = (darwin { enable = false; }).config;
  hmDefault = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = darwinPkgs;
    modules = [
      inputs.self.homeManagerModules.default
      {
        home.username = "nix-test";
        home.homeDirectory = "/Users/nix-test";
        home.stateVersion = "26.05";
        programs.wallpapermachine.enable = true;
      }
    ];
  };

  overrides = {
    playback.otherAudioVolume = 30;
    extraSettings."WallpaperMachine.otherAudioVolume" = 50;
    extraSettings."WallpaperMachine.updates.mode" = "automatic";
  };

  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  invalidHome = preferences: (home { inherit preferences; }).activationPackage.drvPath;
  invalidDarwin =
    preferences:
    (darwin { inherit preferences; })
    .config.home-manager.users.nix-test.home.activation.wallpapermachine.data;
  validAssertions = config: builtins.all (entry: entry.assertion) config.assertions;

  agent = {
    ProgramArguments = [
      "/Users/nix-test/Applications/Home Manager Apps/WallpaperMachine.app/Contents/MacOS/WallpaperMachine"
    ];
    EnvironmentVariables.WALLPAPER_MACHINE_PANEL_AT_LAUNCH = "0";
    RunAtLoad = true;
    KeepAlive = false;
    LimitLoadToSessionType = "Aqua";
    ProcessType = "Interactive";
  };

  activationOrder = map (
    entry: entry.name
  ) (inputs.home-manager.lib.hm.dag.topoSort hm.home.activation).result;
  activationIndex = name: lib.lists.findFirstIndex (entry: entry == name) null activationOrder;

  assertions = [
    (validAssertions hm)
    (validAssertions nd)
    (builtins.elem testPackage hm.home.packages)
    (builtins.elem testPackage nd.home-manager.users.nix-test.home.packages)
    (lib.all (name: hm.launchd.agents.wallpapermachine.config.${name} == agent.${name}) (
      builtins.attrNames agent
    ))
    (lib.all (
      name: nd.home-manager.users.nix-test.launchd.agents.wallpapermachine.config.${name} == agent.${name}
    ) (builtins.attrNames agent))
    (activationIndex "copyApps" < activationIndex "setupLaunchAgents")
    (
      (home {
        launchd = true;
        darwinOptions.copyApps.directory = "Applications/My Apps";
      }).config.launchd.agents.wallpapermachine.config.ProgramArguments
      == [ "/Users/nix-test/Applications/My Apps/WallpaperMachine.app/Contents/MacOS/WallpaperMachine" ]
    )
    (
      (home {
        launchd = true;
        darwinOptions.copyApps.enable = false;
      }).config.launchd.agents.wallpapermachine.config.ProgramArguments
      == [ "${testPackage}/Applications/WallpaperMachine.app/Contents/MacOS/WallpaperMachine" ]
    )
    (!(hmDisabled.home.activation ? wallpapermachine))
    (!(ndDisabled.home-manager.users.nix-test.home.activation ? wallpapermachine))
    (!(hmDisabled.launchd.agents ? wallpapermachine))
    (!(ndDisabled.home-manager.users.nix-test.launchd.agents ? wallpapermachine))
    (!((home { }).config.launchd.agents ? wallpapermachine))
    (!((darwin { }).config.home-manager.users.nix-test.launchd.agents ? wallpapermachine))
    (hmDefault.config.programs.wallpapermachine.package.pname == "wallpapermachine")
    (
      hmDefault.config.programs.wallpapermachine.package.version
      == inputs.self.packages.aarch64-darwin.default.version
    )
    (fails (invalidHome {
      playback.otherAudioAction = "invalid";
    }))
    (fails (invalidHome {
      playback.otherAudioVolume = 101;
    }))
    (fails (invalidHome {
      playback.lowBatteryThreshold = 15;
    }))
    (fails (invalidHome {
      playback.inactivityMinutes = 2;
    }))
    (fails (invalidHome {
      updates.mode = "disabled";
    }))
    (fails (invalidHome {
      desktopPicture.enable = "yes";
    }))
    (fails (invalidHome {
      extraSettings."Example.extra" = [ null ];
    }))
    (fails (invalidDarwin {
      playback.otherAudioVolume = 101;
    }))
    (builtins.isString hm.home.activationPackage.drvPath)
    (builtins.isString nd.home-manager.users.nix-test.home.activationPackage.drvPath)
    (builtins.isString nd.system.build.toplevel.drvPath)
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    (fails (home { hostPkgs = pkgs; }).activationPackage.drvPath)
  ];

  profiles = [
    {
      activation = hm.home.activation.wallpapermachine.data;
      inherit expected;
    }
    {
      activation = nd.home-manager.users.nix-test.home.activation.wallpapermachine.data;
      inherit expected;
    }
    {
      activation = (home { }).config.home.activation.wallpapermachine.data;
      expected = {
        "WallpaperMachine.updates.mode" = "notify";
      };
    }
    {
      activation = (home { preferences = overrides; }).config.home.activation.wallpapermachine.data;
      expected = {
        "WallpaperMachine.otherAudioVolume" = 50;
        "WallpaperMachine.updates.mode" = "automatic";
      };
    }
    {
      activation =
        (home { preferences.playback.otherAudioVolume = null; })
        .config.home.activation.wallpapermachine.data;
      expected = {
        "WallpaperMachine.updates.mode" = "notify";
      };
    }
  ];
in
assert lib.assertMsg (builtins.all (
  value: value
) assertions) "WallpaperMachine module integration checks failed";
pkgs.runCommand "wallpapermachine-module-checks"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    profilesJSON = builtins.toJSON profiles;
    passAsFile = [ "profilesJSON" ];
  }
  ''
    python3 - "$profilesJSONPath" <<'PY'
    import json
    import plistlib
    import shlex
    import sys

    with open(sys.argv[1]) as file:
        profiles = json.load(file)
    for profile in profiles:
        arguments = shlex.split(profile["activation"])
        assert len(arguments) % 6 == 0, arguments
        written = {}
        for offset in range(0, len(arguments), 6):
            command = arguments[offset:offset + 6]
            assert command[:4] == ["run", "/usr/bin/defaults", "write", "app.wallpapermachine"], command
            assert command[4] not in written, command[4]
            written[command[4]] = plistlib.loads(command[5].encode())
        assert written == profile["expected"], (written, profile["expected"])
    PY
    touch "$out"
  ''

{ inputs, pkgs }:

let
  inherit (pkgs) lib;
  darwinPkgs = import inputs.nixpkgs { system = "aarch64-darwin"; };
  testPackage = darwinPkgs.emptyDirectory;

  home =
    {
      settings ? { },
      enable ? true,
      launchd ? false,
      package ? testPackage,
      hostPkgs ? darwinPkgs,
    }:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = hostPkgs;
      modules = [
        inputs.self.homeManagerModules.default
        {
          home.username = "nix-test";
          home.homeDirectory = "/Users/nix-test";
          home.stateVersion = "26.05";
          programs.wallpapermachine = {
            inherit enable package settings;
            launchd.enable = launchd;
          };
        }
      ];
    };

  darwin =
    {
      settings ? { },
      enable ? true,
      launchd ? false,
      package ? testPackage,
    }:
    inputs.nix-darwin.lib.darwinSystem {
      modules = [
        inputs.self.darwinModules.default
        {
          nixpkgs.hostPlatform = "aarch64-darwin";
          system.stateVersion = 6;
          system.primaryUser = "nix-test";
          users.users.nix-test.home = "/Users/nix-test";
          programs.wallpapermachine = {
            inherit enable package settings;
            launchd.enable = launchd;
          };
        }
      ];
    };

  settings = {
    "WallpaperMachine.lowPowerModeAction" = "reduceQuality";
    "WallpaperMachine.otherAudioAction" = "mute";
    "WallpaperMachine.lowBatteryThreshold" = 20;
    "WallpaperMachine.wallpapersMuted" = true;
    "WallpaperMachine.displaySleepAction" = null;
    # Exercise literal keys and nested plist values through the freeform type.
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
  expected = builtins.removeAttrs settings [ "WallpaperMachine.displaySleepAction" ] // {
    "WallpaperMachine.updates.mode" = "notify";
  };

  hm =
    (home {
      inherit settings;
      launchd = true;
    }).config;
  nd =
    (darwin {
      inherit settings;
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

  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  invalidHome = value: (home { settings = value; }).config.home.activation.wallpapermachine.data;
  invalidDarwin =
    value:
    (darwin { settings = value; }).config.system.defaults.CustomUserPreferences."app.wallpapermachine";
  validAssertions = config: builtins.all (entry: entry.assertion) config.assertions;

  agent = {
    ProgramArguments = [
      "${testPackage}/Applications/WallpaperMachine.app/Contents/MacOS/WallpaperMachine"
    ];
    EnvironmentVariables.WALLPAPER_MACHINE_PANEL_AT_LAUNCH = "0";
    RunAtLoad = true;
    KeepAlive = false;
    LimitLoadToSessionType = "Aqua";
    ProcessType = "Interactive";
  };

  assertions = [
    (validAssertions hm)
    (validAssertions nd)
    (nd.system.defaults.CustomUserPreferences."app.wallpapermachine" == expected)
    (builtins.elem testPackage hm.home.packages)
    (builtins.elem testPackage nd.environment.systemPackages)
    (lib.all (name: hm.launchd.agents.wallpapermachine.config.${name} == agent.${name}) (
      builtins.attrNames agent
    ))
    (lib.all (name: nd.launchd.user.agents.wallpapermachine.serviceConfig.${name} == agent.${name}) (
      builtins.attrNames agent
    ))
    (!(hmDisabled.home.activation ? wallpapermachine))
    (!(ndDisabled.system.defaults.CustomUserPreferences ? "app.wallpapermachine"))
    (!(hmDisabled.launchd.agents ? wallpapermachine))
    (!(ndDisabled.launchd.user.agents ? wallpapermachine))
    (!((home { }).config.launchd.agents ? wallpapermachine))
    (!((darwin { }).config.launchd.user.agents ? wallpapermachine))
    (hmDefault.config.programs.wallpapermachine.package.pname == "wallpapermachine")
    (
      hmDefault.config.programs.wallpapermachine.package.version
      == inputs.self.packages.aarch64-darwin.default.version
    )
    (fails (invalidHome {
      "WallpaperMachine.otherAudioAction" = "invalid";
    }))
    (fails (invalidDarwin {
      "WallpaperMachine.otherAudioVolume" = 101;
    }))
    (fails (invalidHome {
      "WallpaperMachine.lowBatteryThreshold" = 15;
    }))
    (fails (invalidDarwin {
      "WallpaperMachine.inactivityMinutes" = 2;
    }))
    (fails (invalidHome {
      "Example.extra" = [ null ];
    }))
    (lib.hasInfix "/usr/bin/defaults write app.wallpapermachine" hm.home.activation.wallpapermachine.data)
    (lib.hasInfix "app.wallpapermachine" nd.system.activationScripts.userDefaults.text)
    # Force the complete activation derivations to evaluate, without building or
    # running any Darwin executable on the machine performing this check.
    (builtins.isString hm.home.activationPackage.drvPath)
    (builtins.isString nd.system.build.toplevel.drvPath)
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    (fails (home { hostPkgs = pkgs; }).activationPackage.drvPath)
  ];
in
assert lib.assertMsg (builtins.all (
  value: value
) assertions) "WallpaperMachine module integration checks failed";
pkgs.runCommand "wallpapermachine-module-checks"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    plist = lib.generators.toPlist { escape = true; } expected;
    expectedJSON = builtins.toJSON expected;
    activation = hm.home.activation.wallpapermachine.data;
    passAsFile = [
      "plist"
      "expectedJSON"
      "activation"
    ];
  }
  ''
    python3 - "$plistPath" "$expectedJSONPath" "$activationPath" <<'PY'
    import json
    import plistlib
    import shlex
    import sys
    with open(sys.argv[1], "rb") as file:
        actual = plistlib.load(file)
    with open(sys.argv[2]) as file:
        expected = json.load(file)
    assert actual == expected, (actual, expected)
    with open(sys.argv[3]) as file:
        arguments = shlex.split(file.read())
    written = {}
    for offset in range(0, len(arguments), 6):
        command = arguments[offset:offset + 6]
        assert command[:4] == ["run", "/usr/bin/defaults", "write", "app.wallpapermachine"], command
        written[command[4]] = plistlib.loads(command[5].encode())
    assert written == expected, (written, expected)
    PY
    touch "$out"
  ''

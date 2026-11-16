{
  lib,
  stdenvNoCC,
  fetchurl,
  _7zz,
  python3,
}:

let
  release = builtins.fromJSON (builtins.readFile ./release.json);
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "wallpapermachine";
  version = release.version;

  src = fetchurl {
    url = "https://github.com/MMFoundation/WallpaperMachine/releases/download/v${finalAttrs.version}/WallpaperMachine-${finalAttrs.version}-arm64.dmg";
    hash = release.hash;
  };

  nativeBuildInputs = [ _7zz ];
  sourceRoot = "WallpaperMachine ${finalAttrs.version}";
  dontConfigure = true;
  dontBuild = true;

  # Stripping, rewriting load paths, or changing bundle resources invalidates
  # the developer signature and the embedded extension's signing contract.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/Applications"
    cp -R WallpaperMachine.app "$out/Applications/"
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ python3 ];
  installCheckPhase = ''
    runHook preInstallCheck
    app="$out/Applications/WallpaperMachine.app"
    diff -r WallpaperMachine.app "$app"
    test -x "$app/Contents/MacOS/WallpaperMachine"
    python3 - "$app" '${finalAttrs.version}' <<'PY'
    import pathlib
    import plistlib
    import struct
    import sys

    app = pathlib.Path(sys.argv[1])
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    assert info["CFBundleIdentifier"] == "app.wallpapermachine", info
    assert info["CFBundleShortVersionString"] == sys.argv[2], info
    assert int(info["LSMinimumSystemVersion"].split(".")[0]) >= 15, info
    with (app / "Contents/MacOS" / info["CFBundleExecutable"]).open("rb") as file:
        magic, cpu = struct.unpack("<II", file.read(8))
    assert magic == 0xFEEDFACF and cpu == 0x0100000C, (magic, cpu)
    extension = app / "Contents/Extensions/WallpaperMachineExtension.appex"
    assert extension.is_dir(), extension
    with (extension / "Contents/Info.plist").open("rb") as file:
        assert plistlib.load(file)["CFBundleIdentifier"] == "app.wallpapermachine.wallpaper-extension"
    PY
    runHook postInstallCheck
  '';

  meta = {
    description = "Play Wallpaper Engine scene, video, and web wallpapers on macOS";
    homepage = "https://github.com/MMFoundation/WallpaperMachine";
    changelog = "https://github.com/MMFoundation/WallpaperMachine/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.gpl3Only;
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})

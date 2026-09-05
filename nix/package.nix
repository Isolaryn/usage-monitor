{ lib, stdenv, swift, swiftpm, rcodesign }:

stdenv.mkDerivation {
  pname = "usage-monitor";
  version = "0.2.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Package.swift
      ../Sources
      ../Resources
    ];
  };

  nativeBuildInputs = [ swift swiftpm rcodesign ];
  swiftpmFlags = [ "--disable-sandbox" ];
  # Nixpkgs' Swift runtime targets macOS 14; match the bundle and package metadata.
  env.MACOSX_DEPLOYMENT_TARGET = "14.0";
  postPatch = ''
    substituteInPlace Package.swift --replace-fail '.macOS(.v13)' '.macOS(.v14)'
    substituteInPlace Resources/Info.plist --replace-fail '<string>13.0</string>' '<string>14.0</string>'
  '';
  doCheck = true;

  preBuild = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export CFFIXED_USER_HOME="$HOME"
  '';

  checkPhase = ''
    runHook preCheck
    "$(swiftpmBinPath)/UsageMonitor" --self-test
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    app="$out/Applications/Usage Monitor.app"
    mkdir -p "$app/Contents/MacOS" "$out/bin"
    cp "$(swiftpmBinPath)/UsageMonitor" "$app/Contents/MacOS/UsageMonitor"
    cp Resources/Info.plist "$app/Contents/Info.plist"

    # Open the bundle for normal use, but permit direct CLI diagnostics/tests.
    cat > "$out/bin/usage-monitor" <<EOF_LAUNCHER
    #!${stdenv.shell}
    if [ "\$#" -gt 0 ]; then
      exec "$app/Contents/MacOS/UsageMonitor" "\$@"
    fi
    exec /usr/bin/open "$app"
    EOF_LAUNCHER
    chmod +x "$out/bin/usage-monitor"
    runHook postInstall
  '';

  postFixup = ''
    rcodesign sign "$out/Applications/Usage Monitor.app"
  '';

  meta = {
    description = "Compact macOS menu bar monitor for Codex and Claude subscription usage";
    platforms = [ "aarch64-darwin" ];
    mainProgram = "usage-monitor";
  };
}

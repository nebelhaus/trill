{
  lib,
  stdenvNoCC,
  fetchurl,
  version,
  sha256,
}:

# Package the published Trill.app so the rice (and anyone) can install it through
# Nix instead of Homebrew — trill's handle in the flake-lock chain.
#
# We fetch the CI-built release ZIP rather than compiling: trill is an Xcode
# project with ~15 SwiftPM packages, and macOS 26 refuses to let a session-less
# `_nixbld` user apply SwiftPM's manifest sandbox, so a from-source Nix build
# dies at package resolution (pounce dodges this only by being plain `swiftc`
# with zero packages). The ZIP is already Developer-ID signed + Apple notarized,
# which is exactly what a stable Full Disk Access grant wants — so unpack it
# verbatim and let the rice place it at a fixed path (no re-sign dance).
stdenvNoCC.mkDerivation {
  pname = "trill";
  inherit version;

  src = fetchurl {
    url = "https://github.com/nebelhaus/trill/releases/download/v${version}/trill-v${version}-macos.zip";
    inherit sha256;
  };

  # `ditto -x -k` is the macOS-correct unarchiver: the release ZIP is written by
  # `ditto -c -k` and carries the code signature + stapled notarization ticket as
  # bundle contents + xattrs. Plain `unzip` can drop those; ditto preserves them,
  # so the extracted app still verifies. The archive holds Trill.app at top level
  # (built with --keepParent), so extract into the cwd.
  unpackPhase = ''
    runHook preUnpack
    /usr/bin/ditto -x -k "$src" .
    runHook postUnpack
  '';

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications
    /usr/bin/ditto Trill.app $out/Applications/Trill.app
    runHook postInstall
  '';

  # Don't let Nix strip or re-sign the notarized bundle — any rewrite invalidates
  # the signature the FDA grant depends on.
  dontFixup = true;

  meta = {
    description = "Native, provider-neutral macOS Messages client (iMessage/SMS/RCS)";
    homepage = "https://github.com/nebelhaus/trill";
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

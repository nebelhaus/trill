{
  description = "Trill — a native, provider-neutral Messages client for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAll = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };

      # The CI-owned release pin (version + sha256 of the notarized .zip).
      release = import ./nix/release.nix;
    in
    {
      # Consume trill from anywhere: `overlays.default` puts `trill` into pkgs.
      # The rice adds this overlay and installs pkgs.trill in place of the cask.
      overlays.default = final: prev: {
        trill = final.callPackage ./nix/package.nix { inherit (release) version sha256; };
      };

      packages = forAll (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.trill;
          trill = pkgs.trill;
        }
      );
    };
}

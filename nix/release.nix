# The published Trill.app release this flake installs.
#
# CI-OWNED: trill's release workflow (release.yml, the `bump-flake` job) rewrites
# these on every tag — the SAME version + SHA it stamps into the Homebrew cask
# (nebelhaus/homebrew-tap, Casks/trill.rb), at the same moment. The flake wraps
# the CI-built, Developer-ID-signed, Apple-notarized release ZIP rather than
# compiling from source: trill is a full Xcode project with ~15 SwiftPM packages,
# and macOS 26 blocks a `_nixbld` build user from applying SwiftPM's manifest
# sandbox (unlike pounce, which is plain `swiftc` with no packages) — so the
# release artifact is the only buildable-anywhere handle on the app. See
# ../nix/package.nix.
#
# Hand-edit only to bootstrap a brand-new release line. `version` carries no
# leading "v"; `sha256` is the release .zip's SHA-256 in hex (what `sha256sum`
# prints — the same value the cask stores).
{
  version = "2026.08.03";
  sha256 = "a5ffa26beeda939d874c09d2d34730ffe9441e7d40d3988c3732e22459a522b0";
}

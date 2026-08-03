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
  version = "2026.08.03-1";
  sha256 = "546bed6d673a93489cf4bb9ef98aa70f6a40aac8191f4de19669027b4f37b93b";
}

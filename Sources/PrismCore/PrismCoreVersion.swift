/// Which PrismCore this is, as released.
///
/// SwiftPM gives a package no way to read its own tag at build time, so the
/// number is written here by hand and bumped with every release (AGENTS.md
/// *Releasing*). A test pins it to the newest version heading in
/// `CHANGELOG.md`, so a release that forgets it fails the suite instead of
/// shipping field reports that name the previous version.
public enum PrismCoreVersion {
    public static let current = "3.5.0"
}

/// Single source of truth for the release version. SwiftPM executables have no
/// Info.plist; packaging/Info.plist's CFBundleShortVersionString is kept in
/// lockstep manually (bump both in the same commit).
public enum MaxMiVersion {
    public static let current = "0.2.0"
}

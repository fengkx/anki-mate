import Foundation

public enum AnkiMateIdentity {
    public static let bundleIdentifier = "dev.ankimate.app"
    public static let legacyBundleIdentifiers = ["dev.dictkit.app"]

    public static let applicationSupportDirectoryName = "Anki Mate"
    public static let legacyApplicationSupportDirectoryNames = ["DictKit"]

    public static let webDAVKeychainService = "\(bundleIdentifier).webdav"
    public static let legacyWebDAVKeychainServices = [
        "com.anki-mate.webdav",
        "dev.dictkit.app.webdav",
        "com.dictkit.webdav",
    ]

    public static let webDAVKeychainAccount = "credentials"
}

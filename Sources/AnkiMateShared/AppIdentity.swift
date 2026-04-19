import Foundation

public enum AnkiMateIdentity {
    public static let displayName = "Anki Mate"
    public static let bundleIdentifier = "dev.ankimate.app"
    public static let legacyBundleIdentifiers = ["dev.dictkit.app"]

    public static let applicationSupportDirectoryName = displayName
    public static let legacyApplicationSupportDirectoryNames = ["DictKit"]
    public static let defaultExportDeckName = "\(displayName) Vocabulary"
    public static let basicNoteTypeName = "\(displayName) Basic"
    public static let recallNoteTypeName = "\(displayName) Recall"
    public static let exportPackageFilenamePrefix = displayName

    public static let webDAVKeychainService = "\(bundleIdentifier).webdav"
    public static let legacyWebDAVKeychainServices = [
        "com.anki-mate.webdav",
        "dev.dictkit.app.webdav",
        "com.dictkit.webdav",
    ]

    public static let webDAVKeychainAccount = "credentials"
}

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macos-dictkit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DictKit", targets: ["DictKit"]),
        .library(name: "DictKitSystemDictionary", targets: ["DictKitSystemDictionary"]),
        .executable(name: "dictkit", targets: ["DictKitExecutable"]),
        .library(name: "DictKitAnkiExport", targets: ["DictKitAnkiExport"]),
        .executable(name: "anki-mate", targets: ["DictKitApp"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.3.0"
        ),
        .package(
            url: "https://github.com/pointfreeco/swift-snapshot-testing",
            exact: "1.18.3"
        ),
        .package(
            url: "https://github.com/scinfu/SwiftSoup",
            from: "2.7.0"
        )
    ],
    targets: [
        .target(
            name: "DictPrivate",
            path: "Sources/DictPrivate",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreServices", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "DictKit",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup")
            ],
            path: "Sources/DictKit"
        ),
        .target(
            name: "DictKitSystemDictionary",
            dependencies: [
                "DictKit",
                .target(name: "DictPrivate", condition: .when(platforms: [.macOS]))
            ],
            path: "Sources/DictKitSystemDictionary",
            linkerSettings: [
                .linkedFramework("AVFAudio", .when(platforms: [.macOS])),
                .linkedFramework("NaturalLanguage", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "DictKitCLI",
            dependencies: [
                "DictKit",
                "DictKitSystemDictionary",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/DictKitCLI"
        ),
        .executableTarget(
            name: "DictKitExecutable",
            dependencies: ["DictKitCLI"],
            path: "Sources/DictKitExecutable"
        ),
        .target(
            name: "DictKitAnkiExport",
            dependencies: ["DictKit"],
            path: "Sources/DictKitAnkiExport"
        ),
        .executableTarget(
            name: "DictKitApp",
            dependencies: [
                "DictKit",
                "DictKitSystemDictionary",
                "DictKitAnkiExport"
            ],
            path: "Sources/DictKitApp"
        ),
        .testTarget(
            name: "DictKitTests",
            dependencies: [
                "DictKit",
                "DictKitCLI",
                "DictKitSystemDictionary",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            path: "Tests/DictKitTests",
            exclude: [
                "__Snapshots__"
            ],
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "AnkiExportTests",
            dependencies: [
                "DictKit",
                "DictKitAnkiExport"
            ],
            path: "Tests/AnkiExportTests"
        ),
        .testTarget(
            name: "DictKitAppTests",
            dependencies: [
                "DictKit",
                "DictKitApp"
            ],
            path: "Tests/DictKitAppTests"
        )
    ]
)

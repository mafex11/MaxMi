// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MaxMi",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CSQLiteVec",
            path: "Vendor/sqlite-vec",
            sources: ["sqlite-vec.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),           // link against real sqlite3 symbols, no ext thunk
                .unsafeFlags(["-Wno-everything"]) // vendored amalgamation, not our lint problem
            ]
        ),
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            exclude: ["ggml-metal.m", "ggml-metal.metal", "coreml"],
            sources: [
                "ggml.c",
                "ggml-alloc.c",
                "ggml-backend.c",
                "ggml-quants.c",
                "whisper.cpp",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("GGML_USE_ACCELERATE"),
                .unsafeFlags(["-Wno-shorten-64-to-32", "-Wno-deprecated-declarations"])
            ],
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),
        .target(name: "MaxMiCore"),
        .target(name: "MaxMiStore", dependencies: [
            "MaxMiCore", "CSQLiteVec",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "MaxMiCapture", dependencies: ["MaxMiCore"]),
        .target(name: "MaxMiRelay", dependencies: ["MaxMiCore"]),
        .target(name: "MaxMiMeetings", dependencies: ["MaxMiCore", "CWhisper"]),
        .executableTarget(name: "MaxMi", dependencies: [
            "MaxMiCore", "MaxMiStore", "MaxMiCapture", "MaxMiRelay", "MaxMiMeetings",
        ]),
        .executableTarget(name: "MaxMiMCP", dependencies: [
            "MaxMiCore", "MaxMiStore", "MaxMiRelay",
        ]),
        .testTarget(name: "MaxMiCoreTests", dependencies: ["MaxMiCore"]),
        .testTarget(name: "MaxMiStoreTests", dependencies: ["MaxMiStore"]),
        .testTarget(name: "MaxMiCaptureTests", dependencies: ["MaxMiCapture"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "MaxMiRelayTests", dependencies: ["MaxMiRelay"]),
        .testTarget(name: "MaxMiMCPTests", dependencies: ["MaxMiMCP"]),
        .testTarget(name: "MaxMiMeetingsTests", dependencies: ["MaxMiMeetings"]),
    ]
)

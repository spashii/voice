// swift-tools-version: 6.0
import PackageDescription

// VoiceCore records, transcribes, cleans up and stores speech, with no UI code, so the
// menu bar app, the command line tool and the call recorder that comes next share it.
let package = Package(
    name: "VoiceCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoiceCore", targets: ["VoiceCore"]),
        .executable(name: "voice-cli", targets: ["voice-cli"]),
    ],
    targets: [
        // whisper.cpp's prebuilt framework, with Metal and its shaders built in. Release b5454
        // is the build of v1.9.5.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .target(
            name: "VoiceCore",
            dependencies: ["whisper"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "voice-cli", dependencies: ["VoiceCore", "whisper"]),
        .testTarget(name: "VoiceCoreTests", dependencies: ["VoiceCore"]),
    ]
)

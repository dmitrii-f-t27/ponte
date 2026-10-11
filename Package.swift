// swift-tools-version: 6.0
import PackageDescription

// Ponte — live PT-BR ⇄ RU translator for Zoom calls (macOS 26+).
// Module ownership is fixed in SPEC.md: one agent per Sources/<Target> folder.
let package = Package(
    name: "Ponte",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Ponte", targets: ["PonteApp"]),
    ],
    targets: [
        .target(name: "PonteCore"),
        .target(name: "PonteAudio", dependencies: ["PonteCore"]),
        .target(name: "PonteSpeech", dependencies: ["PonteCore"]),
        .executableTarget(name: "PonteApp", dependencies: ["PonteCore", "PonteAudio", "PonteSpeech"]),
        .executableTarget(name: "AudioProbe", dependencies: ["PonteCore", "PonteAudio"]),
        .executableTarget(name: "SpeechProbe", dependencies: ["PonteCore", "PonteSpeech"]),
        .testTarget(name: "PonteTests", dependencies: ["PonteCore", "PonteAudio", "PonteSpeech"]),
    ],
    swiftLanguageModes: [.v5]
)

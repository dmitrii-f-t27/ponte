// swift-tools-version: 6.0
import PackageDescription

// Ponte — the owner's own live PT-BR ⇄ RU translator for calls in any app (macOS 26+).
// Module ownership is fixed in SPEC.md: one agent per Sources/<Target> folder.
// Every decision is written in t27 (Specs/*.t27) and compiled to C in Sources/PonteSpecs;
// Swift collects facts, asks a spec, and carries out the answer (OS APIs and UI only).
let package = Package(
    name: "Ponte",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Ponte", targets: ["PonteApp"]),
    ],
    targets: [
        .target(name: "PonteSpecs", cSettings: [.unsafeFlags(["-ffp-contract=off"])]),
        .target(name: "PonteCore"),
        .target(name: "PonteAudio", dependencies: ["PonteCore", "PonteSpecs"]),
        .target(name: "PonteSpeech", dependencies: ["PonteCore", "PonteSpecs"]),
        .executableTarget(name: "PonteApp", dependencies: ["PonteCore", "PonteAudio", "PonteSpeech", "PonteSpecs"]),
        .executableTarget(name: "AudioProbe", dependencies: ["PonteCore", "PonteAudio"]),
        .executableTarget(name: "SpeechProbe", dependencies: ["PonteCore", "PonteSpeech"]),
        .testTarget(name: "PonteTests", dependencies: ["PonteCore", "PonteAudio", "PonteSpeech", "PonteSpecs", "PonteApp"]),
    ],
    swiftLanguageModes: [.v5]
)

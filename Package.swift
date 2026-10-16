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
        .target(name: "PonteCore", dependencies: ["PonteSpecs"]),
        // Catches Objective-C exceptions AVAudioEngine raises (Swift cannot), so a device change never aborts the app.
        .target(name: "PonteObjC"),
        .target(name: "PonteAudio", dependencies: ["PonteCore", "PonteSpecs", "PonteObjC"]),
        .target(name: "PonteSpeech", dependencies: ["PonteCore", "PonteSpecs"]),
        // Two Russians in one call hear each other through an encrypted relay between their Pontes (peer_rules.t27).
        .target(name: "PontePeer", dependencies: ["PonteCore", "PonteSpecs", "PonteAudio"]),
        // The owner's camera picture in Meet: the rules (camera_rules.t27) and the link to the Ponte Camera extension.
        .target(name: "PonteCamera", dependencies: ["PonteSpecs", "PonteAudio"]),
        .executableTarget(name: "PonteApp", dependencies: ["PonteCore", "PonteAudio", "PonteSpeech", "PonteSpecs", "PontePeer", "PonteCamera"]),
        .executableTarget(name: "AudioProbe", dependencies: ["PonteCore", "PonteAudio"]),
        .executableTarget(name: "SpeechProbe", dependencies: ["PonteCore", "PonteSpeech", "PonteSpecs"]),
        .executableTarget(name: "PeerProbe", dependencies: ["PonteAudio", "PontePeer"]),
        .executableTarget(name: "CameraProbe", dependencies: ["PonteCamera"]),
        .testTarget(name: "PonteTests", dependencies: ["PonteCore", "PonteAudio", "PonteSpeech", "PonteSpecs", "PonteApp", "PontePeer", "PonteCamera"]),
    ],
    swiftLanguageModes: [.v5]
)

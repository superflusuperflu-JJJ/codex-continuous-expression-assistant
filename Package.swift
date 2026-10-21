// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ContextCapturePrototype",
    platforms: [.macOS(.v26)],
    products: [.library(name: "PrototypeCore", targets: ["PrototypeCore"]),
               .executable(name: "ContextCapture", targets: ["ContextCapture"])],
    targets: [
        .target(name: "PrototypeCore"),
        .executableTarget(name: "ContextCapture", dependencies: ["PrototypeCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["PrototypeCore"], path: "Tests/PrototypeCoreTests")
    ],
    swiftLanguageModes: [.v5]
)

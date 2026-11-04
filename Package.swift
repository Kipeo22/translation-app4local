// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kotoba",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Kotoba", targets: ["Kotoba"])],
    targets: [
        .executableTarget(name: "Kotoba"),
        .testTarget(name: "KotobaTests", dependencies: ["Kotoba"])
    ],
    swiftLanguageModes: [.v5]
)

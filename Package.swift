// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Simplie",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Simplie", targets: ["Simplie"])
    ],
    targets: [
        .executableTarget(name: "Simplie")
    ]
)
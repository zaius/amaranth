// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Amaranth",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Amaranth", targets: ["Amaranth"])
    ],
    dependencies: [
        .package(url: "https://github.com/NordicSemiconductor/IOS-nRF-Mesh-Library", from: "4.2.0")
    ],
    targets: [
        .executableTarget(
            name: "Amaranth",
            dependencies: [
                .product(name: "NordicMesh", package: "IOS-nRF-Mesh-Library")
            ]
        )
    ]
)

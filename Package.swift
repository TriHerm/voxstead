// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Voxstead",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Voxstead", targets: ["Voxstead"])],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"])
    ],
    targets: [
        .executableTarget(name: "Voxstead", dependencies: [
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "FluidAudio", package: "FluidAudio")
        ]),
        .testTarget(
            name: "VoxsteadTests", dependencies: ["Voxstead"],
            resources: [.copy("Fixtures/mcp_fixture.py")]
        )
    ]
)

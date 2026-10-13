// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GraphiSchema",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GraphiSchema", targets: ["GraphiSchema"]),
    ],
    targets: [
        .executableTarget(
            name: "GraphiSchema",
            path: "Sources/GraphiSchema"
        ),
    ]
)

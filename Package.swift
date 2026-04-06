// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PrimitiveApp",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "PrimitiveApp",
            targets: ["PrimitiveApp"]
        ),
    ],
    dependencies: [
        // During development: local path to the client library
        .package(url: "https://github.com/Primitive-Labs/JsBaoClient.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "PrimitiveApp",
            dependencies: [
                .product(name: "JsBaoClient", package: "JsBaoClient"),
            ],
            path: "Sources/PrimitiveApp"
        ),
    ]
)

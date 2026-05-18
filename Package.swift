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
        // TEMPORARY — pointed at the swift-codegen worktree to
        // dogfood the build-time TOML → Swift model generator. Swap
        // back to `../../js-bao-wss/swift-client` once codegen lands
        // on main. See `TODO_REVERT_SWIFT_CLIENT_PATH.md` at the repo
        // root for the full revert checklist.
        .package(url: "https://github.com/Primitive-Labs/swift-client.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "PrimitiveApp",
            dependencies: [
                .product(name: "JsBaoClient", package: "swift-client"),
            ],
            path: "Sources/PrimitiveApp",
            resources: [
                // Debug inspector's single-page UI, decomposed into one
                // file per tab so the file tree mirrors the UI. Assembled
                // at first access by `InspectorHTML.page`. DEBUG-only at
                // runtime, but the resources still ship in every build
                // (SPM has no build-configuration-gated resources).
                //
                // `.process(dir)` recursively picks up every web resource
                // under `Debug/ui` regardless of how many tab files get
                // added — no need to touch this list when a new tab
                // drops in.
                .process("Debug/ui"),
            ],
            linkerSettings: [
                // DEBUG-only DebugInspector reads the client's SQLite cache read-only.
                .linkedLibrary("sqlite3", .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "PrimitiveAppTests",
            dependencies: ["PrimitiveApp"],
            path: "Tests/PrimitiveAppTests"
        ),
    ]
)

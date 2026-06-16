// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "TsuiseKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "TsuiseKit",
            targets: ["TsuiseKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "TsuiseKit",
            dependencies: ["SwiftSoup"]
        ),
        .testTarget(
            name: "TsuiseKitTests",
            dependencies: ["TsuiseKit"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

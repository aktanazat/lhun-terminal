// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LhunKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "LhunKit", targets: ["LhunKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/aktanazat/SwiftTerm", revision: "e9f96e88c3afb8e859b89b81a6fdde45c7d9d183"),
        // Exact versions, so the app and every app embedding LhunKit build against the same SSH stack.
        .package(url: "https://github.com/apple/swift-nio", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services", exact: "1.28.0"),
    ],
    targets: [
        .target(
            name: "LhunKit",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ],
            path: "Lhun",
            resources: [
                // Bundled under SIL OFL 1.1; retain Fonts/OFL.txt.
                .copy("Fonts"),
                .process("PrivacyInfo.xcprivacy"),
                .copy("ProgramIcons-LICENSE.md"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)

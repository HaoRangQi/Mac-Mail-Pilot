// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MailPilot",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.14.3")
    ],
    targets: [
        .executableTarget(
            name: "MailPilot",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup")
            ],
            path: "Sources/MailPilot",
            resources: [
                .copy("Resources/purify.min.js")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

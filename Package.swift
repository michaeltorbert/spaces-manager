// swift-tools-version:5.9
//
// IDE indexing only — not the build.
//
// The real build is build.sh, which links against the vendored
// Frameworks/Sparkle.framework with ad-hoc signing. This manifest exists so
// Xcode (via "Open Package.swift") and VS Code with the Swift extension can
// resolve Sparkle types for autocomplete and inline errors.
//
// Sparkle is declared as an SPM dependency below AND vendored under
// Frameworks/ by build.sh — keep the versions in lockstep when upgrading.
// Do not migrate the actual build to `swift build`; it would lose the
// ad-hoc-signed nested-framework setup that build.sh handles.

import PackageDescription

let package = Package(
    name: "SpacesManager",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2"),
    ],
    targets: [
        .executableTarget(
            name: "SpacesManager",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources"
        ),
    ]
)

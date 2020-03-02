// swift-tools-version:5.1
import PackageDescription

let package = Package(
    name: "IdentityCore",
    products: [
        .library(
            name: "IdentityCore",
            targets: ["IdentityCore"]
        ),
    ],
    targets: [
        .target(
            name: "IdentityCore",
            path: "IdentityCore/src",
            cxxSettings: [
                .headerSearchPath("."),
                .headerSearchPath("configuration/webview"),
                .headerSearchPath("oauth2"),
                .headerSearchPath("oauth2/aad_base"),
                .headerSearchPath("oauth2/aad_v1"),
                .headerSearchPath("oauth2/aad_v2"),
                .headerSearchPath("oauth2/token"),
                .headerSearchPath("webview"),
                .headerSearchPath("webview/background/ios"),
                .headerSearchPath("telemetry"),
                .headerSearchPath("webview/response"),
                .headerSearchPath("workplacejoin"),
                .headerSearchPath("util")
            ]
            )
    ]
)
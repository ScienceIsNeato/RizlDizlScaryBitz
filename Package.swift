// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RizlDizlScaryBitz",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RizlDizlScaryBitz", targets: ["RizlDizlScaryBitz"])
    ],
    targets: [
        // C device transport: an original implementation of the Razer USB
        // lighting protocol over IOKit. No third-party driver code.
        .target(
            name: "CRazerBridge",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        // Swift layer: everything that touches the user's machine — global key
        // capture, permission handling, USB hotplug watching, device I/O.
        // Open by design so anyone can audit exactly what we read and where it goes.
        .target(
            name: "RizlDizlScaryBitz",
            dependencies: ["CRazerBridge"]
        )
    ]
)

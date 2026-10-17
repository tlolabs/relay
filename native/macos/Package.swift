// swift-tools-version: 5.9
import Foundation
import PackageDescription

let rustLibrary = ProcessInfo.processInfo.environment["RUST_LIB_DIR"] ?? "../../target/debug"
let package = Package(
    name: "RelayObserver",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "RelayObserver", targets: ["RelayObserver"]), .executable(name: "Relay", targets: ["Relay"])],
    targets: [
        .target(name: "IFlicksCapture"),
        .systemLibrary(name: "CRelayCore", path: "Sources/CRelayCore"),
        .target(name: "RelayKit", dependencies: ["CRelayCore", "IFlicksCapture"], linkerSettings: [
            .unsafeFlags(["-L", rustLibrary, "-lrelay_core", "-Xlinker", "-rpath", "-Xlinker", rustLibrary]),
            .linkedFramework("Security"), .linkedFramework("AppKit")
        ]),
        .testTarget(name: "RelayKitTests", dependencies: ["RelayKit"]),
        .executableTarget(name: "Relay", dependencies: ["RelayKit", "IFlicksCapture"], exclude: ["Resources"], linkerSettings: [
            .unsafeFlags(["-L", rustLibrary, "-lrelay_core", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            .linkedFramework("AppKit"), .linkedFramework("UserNotifications"), .linkedFramework("ServiceManagement")
        ]),
        .testTarget(name: "IFlicksCaptureTests", dependencies: ["IFlicksCapture"]),
        .systemLibrary(name: "CRelayObserver", path: "Sources/CRelayObserver"),
        .executableTarget(
            name: "RelayObserver", dependencies: ["CRelayObserver", "IFlicksCapture"],
            linkerSettings: [
                .unsafeFlags(["-L", rustLibrary, "-lrelay_observer_core", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AppKit"), .linkedFramework("CoreServices")
            ]
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmberFM",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AmberFM", targets: ["AmberFM"])],
    targets: [
        .target(name: "CDSP", publicHeadersPath: "include", cxxSettings: [.unsafeFlags(["-O3"])]),
        .executableTarget(name: "AmberFM", dependencies: ["CDSP"],
                          linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit"),
                                           .linkedFramework("AVFoundation"), .linkedFramework("CoreMIDI")])
    ],
    cxxLanguageStandard: .cxx17
)

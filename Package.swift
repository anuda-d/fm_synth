// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FMSynth",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FMSynth", targets: ["FMSynth"])],
    targets: [
        .target(name: "CDSP", path: "src/CDSP", publicHeadersPath: "include", cxxSettings: [.unsafeFlags(["-O3"])]),
        .executableTarget(name: "FMSynth", dependencies: ["CDSP"], path: "src/AmberFM",
                          linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit"),
                                           .linkedFramework("AVFoundation"), .linkedFramework("CoreMIDI")])
    ],
    cxxLanguageStandard: .cxx17
)

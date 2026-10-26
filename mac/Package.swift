// swift-tools-version: 5.9
import PackageDescription
import Foundation

// The CLT Swift Build backend does not discover its bundled Testing macros.
let testingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testingSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPlugins + "/libTestingMacros.dylib")
    ? [.unsafeFlags(["-plugin-path", testingPlugins])] : []

let package = Package(
    name: "AISubGauge",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "AISubGauge", targets: ["TidyBar"])],
    targets: [
        .systemLibrary(name: "SystemMembership"),
        .target(name: "MenuBarShim", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .executableTarget(name: "TidyBar", dependencies: ["SystemMembership", "MenuBarShim"]),
        .testTarget(name: "TidyBarTests", dependencies: ["TidyBar"], swiftSettings: testingSettings)
    ],
    swiftLanguageVersions: [.v5]
)

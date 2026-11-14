// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Notify",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Notify", targets: ["NotifyApp"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3")],
    targets: [
        .target(name: "NotifyCore", dependencies: ["Yams"]),
        .executableTarget(name: "NotifyApp", dependencies: ["NotifyCore"]),
        .executableTarget(name: "NotifyCoreChecks", dependencies: ["NotifyCore"], path: "Tests/NotifyCoreTests"),
        .executableTarget(name: "NotifyTransportChecks", dependencies: ["NotifyCore"], path: "Tests/Transport"),
        .executableTarget(name: "NotifyTerminalChecks", dependencies: ["NotifyCore"], path: "Tests/Terminal")
    ]
)

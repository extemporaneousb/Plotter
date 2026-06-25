// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PlotterVision",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PlotterVision", targets: ["PlotterVision"])
    ],
    targets: [
        .executableTarget(
            name: "PlotterVision",
            path: "Sources/PlotterVision"
        )
    ]
)

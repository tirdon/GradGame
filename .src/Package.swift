// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.


import PackageDescription

let package = Package(
    name: "GradGame",
	platforms: [.macOS(.v26)],
    products: [
		
    ],
    targets: [
        .executableTarget(
            name: "GradGame"
        ),
        .testTarget(
            name: "GradGameTests",
            dependencies: ["GradGame"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

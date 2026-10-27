// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FileAdmiral",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FileAdmiral",
            path: "Sources/FileAdmiral"
        )
    ]
)

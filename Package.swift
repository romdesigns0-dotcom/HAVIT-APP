// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Havit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Havit", targets: ["Havit"]),
        .library(name: "Shared", targets: ["Shared"]),
        .library(name: "HavitWidget", targets: ["HavitWidget"]),
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "12.0.0"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", from: "10.0.0"),
    ],
    targets: [
        .target(name: "Shared"),
        .target(name: "Havit", dependencies: ["Shared", .product(name: "FirebaseCore", package: "firebase-ios-sdk"), .product(name: "FirebaseAuth", package: "firebase-ios-sdk"), .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS")], resources: [.process("Resources")], linkerSettings: [.unsafeFlags(["-Xlinker", "-ObjC"])]),
        .target(name: "HavitWidget", dependencies: ["Shared"]),
    ],
    swiftLanguageModes: [.v5]
)
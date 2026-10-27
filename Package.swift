// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FolderFlow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FolderFlow", targets: ["FolderFlow"])
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", exact: "12.19.3"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", exact: "10.0.0")
    ],
    targets: [
        .executableTarget(
            name: "FolderFlow",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
                .product(name: "GoogleSignInSwift", package: "GoogleSignIn-iOS")
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-ObjC"])]
        ),
        .testTarget(name: "FolderFlowTests", dependencies: ["FolderFlow"]),
        .executableTarget(
            name: "DistributionSmoke",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS")
            ],
            path: "Tests/DistributionSmoke",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-ObjC"])]
        )
    ]
)
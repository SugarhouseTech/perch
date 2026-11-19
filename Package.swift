// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode: the compiler checks which thread or actor each piece
// of state belongs to. The upcoming features are ones Swift 7 turns on; each
// is adopted early because it makes the code say more of what it means.
let swiftSettings: [SwiftSetting] = [
    // `any P` for an existential, so its cost is visible at the use site.
    .enableUpcomingFeature("ExistentialAny"),
    // A file sees only the members of modules it imports itself.
    .enableUpcomingFeature("MemberImportVisibility"),
    // A main actor type's protocol conformances are main actor too.
    .enableUpcomingFeature("InferIsolatedConformances"),
    // A nonisolated async function runs on its caller's actor, not a
    // background thread, unless it says `@concurrent`.
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    // A `weak` capture that is never reassigned is a `let`.
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]

// The download from sugarhouse.tech is built with PERCH_DIRECT=1. It adds
// Sparkle for updates and the trial and licence code. A build from source
// leaves both out, so it needs nothing beyond the Xcode command line tools.
let direct = Context.environment["PERCH_DIRECT"] == "1"
let directDependencies: [Package.Dependency] = direct
    ? [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")] : []
let directTargetDependencies: [Target.Dependency] = direct
    ? [.product(name: "Sparkle", package: "Sparkle")] : []
let directSwiftSettings: [SwiftSetting] = direct ? [.define("PERCH_DIRECT")] : []
// The release script copies Sparkle into Contents/Frameworks.
let directLinkerSettings: [LinkerSetting] = direct
    ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])] : []

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    dependencies: directDependencies,
    targets: [
        .executableTarget(
            name: "Perch",
            dependencies: directTargetDependencies,
            path: "Sources",
            // An app runs on the main thread unless it says otherwise. The
            // pure logic (see AGENTS.md) is marked `nonisolated`, so tests
            // and background queues can call it directly.
            swiftSettings: swiftSettings + [.defaultIsolation(MainActor.self)] + directSwiftSettings,
            linkerSettings: directLinkerSettings + [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "PerchTests",
            dependencies: ["Perch"],
            path: "Tests/PerchTests",
            swiftSettings: swiftSettings
        ),
    ]
)

// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "spm-bundler",
    platforms: [.macOS(.v12)],
    products: [
        .plugin(
            name: "BundlerPlugin",
            targets: ["BundlerPlugin"]
        )
    ],
    targets: [
        .plugin(
            name: "BundlerPlugin",
            capability: .command(
                intent: .custom(verb: "bundle", description: "Create app bundles from a package using .spm-bundler.json")
            ),
            path: "Plugins/BundlerPlugin"
        )
    ]
)

import Foundation
import PackagePlugin

@main
struct BundlerPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let packageURL = URL(fileURLWithPath: context.package.directory.string)
        try BundlerCore().run(
            packageDirectory: packageURL,
            arguments: arguments,
            buildSystem: .swiftPackage
        )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension BundlerPlugin: XcodeCommandPlugin {
    func performCommand(context: XcodePluginContext, arguments: [String]) async throws {
        let projectURL = URL(fileURLWithPath: context.xcodeProject.directory.string)
        try BundlerCore().run(
            packageDirectory: projectURL,
            arguments: arguments,
            buildSystem: .xcode
        )
    }
}
#endif

// MARK: - Core

struct BundlerCore {
    enum BuildSystem: String {
        case swiftPackage
        case xcode
    }

    func run(packageDirectory: URL, arguments: [String], buildSystem: BuildSystem) throws {
        let options = try Options(arguments: arguments, packageDirectory: packageDirectory)
        let configURL = options.configPath ?? packageDirectory.appendingPathComponent(".spm-bundler.json")

        let config = try BundlerConfig.load(from: configURL)
        let configuration = options.configuration ?? config.configuration ?? "release"
        let outputDirectory = options.outputPath
            ?? (config.outputDirectory.flatMap { absolutePath(for: $0, relativeTo: packageDirectory) })
            ?? packageDirectory.appendingPathComponent("Bundles")

        log("Bundling using \(configURL.path) -> \(outputDirectory.path)", verboseOnly: false, options: options)

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for bundle in config.bundles {
            try bundle.validate()
            try bundleApp(
                spec: bundle,
                configuration: configuration,
                packageDirectory: packageDirectory,
                outputDirectory: outputDirectory,
                buildSystem: buildSystem,
                options: options
            )
        }
    }

    private func bundleApp(
        spec: BundleSpec,
        configuration: String,
        packageDirectory: URL,
        outputDirectory: URL,
        buildSystem: BuildSystem,
        options: Options
    ) throws {
        let fileManager = FileManager.default
        let bundleURL = outputDirectory.appendingPathComponent("\(spec.name).app")
        if fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.removeItem(at: bundleURL)
        }

        let executableURL = try resolveBinary(
            for: spec,
            configuration: configuration,
            packageDirectory: packageDirectory,
            buildSystem: buildSystem,
            options: options
        )

        switch spec.platform {
        case .macOS:
            try createMacOSBundle(
                spec: spec,
                executableURL: executableURL,
                bundleURL: bundleURL,
                packageDirectory: packageDirectory,
                options: options
            )
        case .iOS:
            try createIOSBundle(
                spec: spec,
                executableURL: executableURL,
                bundleURL: bundleURL,
                packageDirectory: packageDirectory,
                options: options
            )
        }

        if let signing = spec.signing, signing.isEnabled && !options.skipSigning {
            try signBundle(at: bundleURL, signing: signing, options: options)
        } else {
            log("Skipping signing for \(spec.name)", verboseOnly: true, options: options)
        }
    }

    // MARK: Bundle creation

    private func createMacOSBundle(
        spec: BundleSpec,
        executableURL: URL,
        bundleURL: URL,
        packageDirectory: URL,
        options: Options
    ) throws {
        let fileManager = FileManager.default
        let contents = bundleURL.appendingPathComponent("Contents")
        let macOSDir = contents.appendingPathComponent("MacOS")
        let frameworksDir = contents.appendingPathComponent("Frameworks")
        let resourcesDir = contents.appendingPathComponent("Resources")

        try [bundleURL, contents, macOSDir, frameworksDir, resourcesDir].forEach {
            try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let executableDestination = macOSDir.appendingPathComponent(executableURL.lastPathComponent)
        try copyReplacingItem(at: executableURL, to: executableDestination)
        try makeExecutable(at: executableDestination)

        try copyFrameworks(spec.frameworks, to: frameworksDir, packageDirectory: packageDirectory, options: options)
        try copyResources(spec.resources, to: resourcesDir, packageDirectory: packageDirectory, options: options)

        let infoPlistPath = spec.infoPlist.flatMap { absolutePath(for: $0, relativeTo: packageDirectory) }
        if let infoPlistPath {
            try copyReplacingItem(at: infoPlistPath, to: contents.appendingPathComponent("Info.plist"))
        } else {
            let plist = InfoPlistBuilder.makeMacOSPlist(spec: spec)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        }

        log("Created macOS bundle \(bundleURL.path)", verboseOnly: false, options: options)
    }

    private func createIOSBundle(
        spec: BundleSpec,
        executableURL: URL,
        bundleURL: URL,
        packageDirectory: URL,
        options: Options
    ) throws {
        let fileManager = FileManager.default
        let frameworksDir = bundleURL.appendingPathComponent("Frameworks")
        let resourcesDir = bundleURL.appendingPathComponent("Resources")

        try [bundleURL, frameworksDir, resourcesDir].forEach {
            try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let executableDestination = bundleURL.appendingPathComponent(executableURL.lastPathComponent)
        try copyReplacingItem(at: executableURL, to: executableDestination)
        try makeExecutable(at: executableDestination)

        try copyFrameworks(spec.frameworks, to: frameworksDir, packageDirectory: packageDirectory, options: options)
        try copyResources(spec.resources, to: resourcesDir, packageDirectory: packageDirectory, options: options)

        let infoPlistPath = spec.infoPlist.flatMap { absolutePath(for: $0, relativeTo: packageDirectory) }
        if let infoPlistPath {
            try copyReplacingItem(at: infoPlistPath, to: bundleURL.appendingPathComponent("Info.plist"))
        } else {
            let plist = InfoPlistBuilder.makeIOSPlist(spec: spec)
            try plist.write(to: bundleURL.appendingPathComponent("Info.plist"))
        }

        log("Created iOS bundle \(bundleURL.path)", verboseOnly: false, options: options)
    }

    // MARK: Signing

    private func signBundle(at path: URL, signing: SigningConfig, options: Options) throws {
        guard let identity = signing.identity, !identity.isEmpty else {
            log("No signing identity provided; skipping codesign for \(path.lastPathComponent)", verboseOnly: true, options: options)
            return
        }

        log("Signing \(path.lastPathComponent) with identity \(identity)", verboseOnly: false, options: options)
        var args = ["codesign", "--force", "--sign", identity]
        if let entitlements = signing.entitlements {
            args += ["--entitlements", entitlements]
        }
        if let opts = signing.options, !opts.isEmpty {
            args += ["--options", opts.joined(separator: ",")]
        } else {
            args += ["--options", "runtime"]
        }
        if signing.deep ?? false {
            args.append("--deep")
        }
        args.append(path.path)
        try runProcess(arguments: args, workingDirectory: path.deletingLastPathComponent(), options: options)
    }

    // MARK: Helpers

    private func resolveBinary(
        for spec: BundleSpec,
        configuration: String,
        packageDirectory: URL,
        buildSystem: BuildSystem,
        options: Options
    ) throws -> URL {
        if let provided = spec.binaryPath {
            return absolutePath(for: provided, relativeTo: packageDirectory)
        }

        switch buildSystem {
        case .swiftPackage:
            return try buildSwiftPMProduct(
                product: spec.product,
                configuration: configuration,
                packageDirectory: packageDirectory,
                options: options
            )
        case .xcode:
            // For Xcode, assume the product has been built and exists next to DerivedData build products.
            // Users can override with `binaryPath` for more control.
            return try buildSwiftPMProduct(
                product: spec.product,
                configuration: configuration,
                packageDirectory: packageDirectory,
                options: options
            )
        }
    }

    private func buildSwiftPMProduct(
        product: String,
        configuration: String,
        packageDirectory: URL,
        options: Options
    ) throws -> URL {
        log("Building \(product) (\(configuration)) via swift build", verboseOnly: false, options: options)
        let result = try runProcess(
            arguments: [
                "swift", "build",
                "--product", product,
                "--configuration", configuration,
                "--show-bin-path"
            ],
            workingDirectory: packageDirectory,
            options: options
        )

        guard let binPath = result.output
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else {
            throw BundlerError.buildFailed("Unable to locate build output path for \(product)")
        }

        let binary = URL(fileURLWithPath: binPath).appendingPathComponent(product)
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw BundlerError.buildFailed("Built product not found at \(binary.path)")
        }

        return binary
    }

    private func copyFrameworks(
        _ frameworks: [String]?,
        to destination: URL,
        packageDirectory: URL,
        options: Options
    ) throws {
        guard let frameworks, !frameworks.isEmpty else { return }
        for framework in frameworks {
            let source = absolutePath(for: framework, relativeTo: packageDirectory)
            let target = destination.appendingPathComponent(source.lastPathComponent)
            try copyReplacingItem(at: source, to: target)
            log("Copied framework \(source.lastPathComponent)", verboseOnly: true, options: options)
        }
    }

    private func copyResources(
        _ resources: [String]?,
        to destination: URL,
        packageDirectory: URL,
        options: Options
    ) throws {
        guard let resources, !resources.isEmpty else { return }
        for resource in resources {
            let source = absolutePath(for: resource, relativeTo: packageDirectory)
            let target = destination.appendingPathComponent(source.lastPathComponent)
            try copyReplacingItem(at: source, to: target)
            log("Copied resource \(source.lastPathComponent)", verboseOnly: true, options: options)
        }
    }

    @discardableResult
    private func runProcess(arguments: [String], workingDirectory: URL, options: Options) throws -> ProcessResult {
        let process = Process()
        process.currentDirectoryURL = workingDirectory
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        let errors = String(decoding: errorData, as: UTF8.self)

        log(output.trimmingCharacters(in: .whitespacesAndNewlines), verboseOnly: true, options: options)
        if process.terminationStatus != 0 {
            throw BundlerError.commandFailed(arguments.joined(separator: " "), errors: errors)
        }

        return ProcessResult(output: output, errors: errors)
    }
}

// MARK: - Models

struct BundlerConfig: Decodable {
    var configuration: String?
    var outputDirectory: String?
    var bundles: [BundleSpec]

    static func load(from url: URL) throws -> BundlerConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BundlerError.configMissing(url.path)
        }

        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(BundlerConfig.self, from: data)
        } catch {
            throw BundlerError.configInvalid("Failed to decode \(url.lastPathComponent): \(error)")
        }
    }
}

struct BundleSpec: Decodable {
    enum Platform: String, Decodable {
        case macOS = "macos"
        case iOS = "ios"
    }

    var name: String
    var product: String
    var platform: Platform
    var bundleIdentifier: String
    var version: String
    var displayName: String?
    var minimumSystemVersion: String?
    var infoPlist: String?
    var resources: [String]?
    var frameworks: [String]?
    var binaryPath: String?
    var signing: SigningConfig?

    func validate() throws {
        guard !name.isEmpty else { throw BundlerError.configInvalid("Bundle name is missing") }
        guard !product.isEmpty else { throw BundlerError.configInvalid("Product is missing for \(name)") }
        guard !bundleIdentifier.isEmpty else { throw BundlerError.configInvalid("Bundle identifier is missing for \(name)") }
        guard !version.isEmpty else { throw BundlerError.configInvalid("Version is missing for \(name)") }
    }
}

struct SigningConfig: Decodable {
    var identity: String?
    var entitlements: String?
    var options: [String]?
    var deep: Bool?
    var enabled: Bool?

    var isEnabled: Bool { enabled ?? true }
}

struct Options {
    var configPath: URL?
    var outputPath: URL?
    var configuration: String?
    var verbose: Bool
    var skipSigning: Bool

    init(arguments: [String], packageDirectory: URL) throws {
        var iterator = arguments.makeIterator()
        var parsedConfig: URL?
        var parsedOutput: URL?
        var parsedConfiguration: String?
        var verbose = false
        var skipSigning = false

        while let arg = iterator.next() {
            switch arg {
            case "--config":
                guard let value = iterator.next() else { throw BundlerError.configInvalid("--config requires a path") }
                parsedConfig = absolutePath(for: value, relativeTo: packageDirectory)
            case "--output":
                guard let value = iterator.next() else { throw BundlerError.configInvalid("--output requires a path") }
                parsedOutput = absolutePath(for: value, relativeTo: packageDirectory)
            case "--configuration":
                guard let value = iterator.next() else { throw BundlerError.configInvalid("--configuration requires a value") }
                parsedConfiguration = value
            case "--verbose":
                verbose = true
            case "--skip-sign":
                skipSigning = true
            default:
                break
            }
        }

        self.configPath = parsedConfig
        self.outputPath = parsedOutput
        self.configuration = parsedConfiguration
        self.verbose = verbose
        self.skipSigning = skipSigning
    }
}

struct ProcessResult {
    var output: String
    var errors: String
}

enum BundlerError: Error, CustomStringConvertible {
    case configMissing(String)
    case configInvalid(String)
    case buildFailed(String)
    case commandFailed(String, errors: String)

    var description: String {
        switch self {
        case .configMissing(let path):
            return "Configuration file not found at \(path)"
        case .configInvalid(let message):
            return message
        case .buildFailed(let message):
            return "Build failed: \(message)"
        case .commandFailed(let command, let errors):
            return "Command '\(command)' failed with: \(errors)"
        }
    }
}

// MARK: - Info.plist creation

enum InfoPlistBuilder {
    static func makeMacOSPlist(spec: BundleSpec) -> NSDictionary {
        var dict: [String: Any] = [
            "CFBundleName": spec.displayName ?? spec.name,
            "CFBundleDisplayName": spec.displayName ?? spec.name,
            "CFBundleExecutable": spec.product,
            "CFBundleIdentifier": spec.bundleIdentifier,
            "CFBundleVersion": spec.version,
            "CFBundleShortVersionString": spec.version,
            "CFBundlePackageType": "APPL",
            "LSMinimumSystemVersion": spec.minimumSystemVersion ?? "12.0"
        ]
        dict["CFBundleSupportedPlatforms"] = ["MacOSX"]
        return dict as NSDictionary
    }

    static func makeIOSPlist(spec: BundleSpec) -> NSDictionary {
        var dict: [String: Any] = [
            "CFBundleName": spec.displayName ?? spec.name,
            "CFBundleDisplayName": spec.displayName ?? spec.name,
            "CFBundleExecutable": spec.product,
            "CFBundleIdentifier": spec.bundleIdentifier,
            "CFBundleVersion": spec.version,
            "CFBundleShortVersionString": spec.version,
            "CFBundlePackageType": "APPL",
            "UIDeviceFamily": [1, 2],
            "CFBundleSupportedPlatforms": ["iPhoneOS"]
        ]
        if let minVersion = spec.minimumSystemVersion {
            dict["MinimumOSVersion"] = minVersion
        }
        return dict as NSDictionary
    }
}

// MARK: - File helpers

func absolutePath(for path: String, relativeTo base: URL) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path)
    } else {
        return base.appendingPathComponent(path)
    }
}

func copyReplacingItem(at source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
    }
    try fileManager.copyItem(at: source, to: destination)
}

func makeExecutable(at url: URL) throws {
    var attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let permissions = attributes[.posixPermissions] as? NSNumber {
        let newPermissions = permissions.uint16Value | UInt16(0o111)
        attributes[.posixPermissions] = NSNumber(value: newPermissions)
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
}

func log(_ message: String, verboseOnly: Bool, options: Options) {
    guard !message.isEmpty else { return }
    if verboseOnly {
        guard options.verbose else { return }
    }
    print("[spm-bundler] \(message)")
}

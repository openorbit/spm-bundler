import PackagePlugin
import Foundation

@main
struct BundlerPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let packageDir = context.package.directory
        let configPath = packageDir.appending(component: ".spm-bundler.json")
        let fm = FileManager.default

        guard fm.fileExists(atPath: configPath.string) else {
            throw NSError(domain: "BundlerPlugin", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing .spm-bundler.json in package root (")])
        }

        let baseURL = URL(fileURLWithPath: packageDir.string)
        let configURL = URL(fileURLWithPath: configPath.string)
        let data = try Data(contentsOf: configURL)
        let decoder = JSONDecoder()
        let cfg = try decoder.decode(BundlerConfig.self, from: data)

        let outRelative = cfg.outputPath ?? "build/\(cfg.bundleName).app"
        let outputURL = baseURL.appendingPathComponent(outRelative, isDirectory: true)

        try prepareBundle(outputURL: outputURL, cfg: cfg, baseURL: baseURL, fm: fm)

        if let identity = cfg.signingIdentity {
            try codesign(path: outputURL.path, identity: identity, entitlements: cfg.entitlementsPath.map { baseURL.appendingPathComponent($0).path })
        }

        print("Created bundle at: \(outputURL.path)")
    }

    func prepareBundle(outputURL: URL, cfg: BundlerConfig, baseURL: URL, fm: FileManager) throws {
        let contents = outputURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSDir = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesDir = contents.appendingPathComponent("Resources", isDirectory: true)
        let frameworksDir = contents.appendingPathComponent("Frameworks", isDirectory: true)

        try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true)

        // Copy executable
        let execSrc = resolvedPath(cfg.executablePath, baseURL: baseURL)
        let execDst = macOSDir.appendingPathComponent(cfg.executableName)
        try removeIfExists(execDst.path, fm: fm)
        try fm.copyItem(atPath: execSrc, toPath: execDst.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execDst.path)

        // Copy frameworks
        for fw in cfg.frameworks {
            let src = resolvedPath(fw, baseURL: baseURL)
            let dst = frameworksDir.appendingPathComponent(URL(fileURLWithPath: src).lastPathComponent)
            try removeIfExists(dst.path, fm: fm)
            try fm.copyItem(atPath: src, toPath: dst.path)
        }

        // Copy resources
        for res in cfg.resources {
            let src = resolvedPath(res, baseURL: baseURL)
            let dst = resourcesDir.appendingPathComponent(URL(fileURLWithPath: src).lastPathComponent)
            try removeIfExists(dst.path, fm: fm)
            try fm.copyItem(atPath: src, toPath: dst.path)
        }

        // Write Info.plist
        let info: [String: Any] = [
            "CFBundleIdentifier": cfg.bundleIdentifier,
            "CFBundleExecutable": cfg.executableName,
            "CFBundleName": cfg.bundleName,
            "CFBundleVersion": cfg.version ?? "1.0",
            "CFBundlePackageType": "APPL",
            "CFBundleSignature": "????"
        ]

        let plistURL = contents.appendingPathComponent("Info.plist")
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: plistURL)
    }

    func resolvedPath(_ path: String, baseURL: URL) -> String {
        if path.hasPrefix("/") { return path }
        return baseURL.appendingPathComponent(path).path
    }

    func removeIfExists(_ path: String, fm: FileManager) throws {
        if fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
    }

    func codesign(path: String, identity: String, entitlements: String?) throws {
        var args = ["--deep", "--force", "--sign", identity, path]
        if let ent = entitlements {
            args.insert(contentsOf: ["--entitlements", ent], at: 0)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let str = String(data: data, encoding: .utf8) ?? "(no output)"
            throw NSError(domain: "BundlerPlugin.codesign", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "codesign failed: \(str)"])
        }
    }
}

struct BundlerConfig: Codable {
    var bundleName: String
    var bundleIdentifier: String
    var executableName: String
    var executablePath: String
    var frameworks: [String]
    var resources: [String]
    var signingIdentity: String?
    var entitlementsPath: String?
    var outputPath: String?
    var version: String?
}

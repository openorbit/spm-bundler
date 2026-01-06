# spm-bundler

SwiftPM command plugin for assembling macOS/iOS `.app` bundles from Swift packages using a JSON configuration file.

## Usage

- Create a config at `.spm-bundler.json` (or pass `--config path/to/config.json`). See `spm-bundler.json.example` for a starting point.
- Run the plugin: `swift package --allow-writing-to-package-directory bundle [--configuration release] [--output Bundles] [--verbose] [--skip-sign]`
  - The plugin builds the listed products (unless `binaryPath` is provided), copies resources/frameworks, writes an `Info.plist` (or uses yours), and optionally codesigns.
  - Output defaults to `Bundles/<Name>.app` under the package root.

## Configuration schema

Top-level keys:
- `configuration` (optional): build configuration to request from `swift build` (default `release`).
- `outputDirectory` (optional): where bundles are emitted; defaults to `Bundles`.
- `bundles`: array of bundle specs.

Bundle fields:
- `name`: display name for the emitted `.app`.
- `product`: SwiftPM product to build/copy into the bundle (ignored when `binaryPath` is used).
- `platform`: `macos` or `ios`.
- `bundleIdentifier`: reverse-DNS identifier.
- `version`: version used for both `CFBundleVersion` and `CFBundleShortVersionString`.
- `minimumSystemVersion` (optional): sets `LSMinimumSystemVersion` (macOS) or `MinimumOSVersion` (iOS).
- `displayName` (optional): overrides the name shown in the plist.
- `infoPlist` (optional): path to an existing plist to copy instead of the generated one.
- `resources` (optional): file/directory paths copied into `Resources` (macOS) or the app root/Resources (iOS).
- `frameworks` (optional): file/directory paths copied into `Frameworks`.
- `binaryPath` (optional): explicit path to a prebuilt binary (useful for iOS/xcconfigs). Otherwise `swift build --product` is invoked.
- `signing` (optional):
  - `enabled` (default `true`), `identity`, `entitlements`, `options` (array passed to `codesign --options`, default `runtime`), `deep` (adds `--deep`).

## Signing notes

- Codesigning is skipped if `signing.enabled` is false, `identity` is empty, or `--skip-sign` is supplied.
- Frameworks/resources are copied as-is; provide pre-signed frameworks if required by your workflow.

## Example

- Copy `spm-bundler.json.example` to `.spm-bundler.json`, update product names/paths/identities, then run:
  - `swift package --allow-writing-to-package-directory bundle --verbose`

# angle-package

Standalone packaging layer for [ANGLE](https://chromium.googlesource.com/angle/angle)
(OpenGL ES over Metal/Vulkan/D3D), producing signed `.xcframework` packages
for iOS and macOS. Designed so Android and Windows packaging can be added as
sibling targets later.

## What this produces

`dist/` contains two multi-slice xcframeworks:

- **`EGL.xcframework`** — libEGL, with slices for:
  - `ios-arm64` (device)
  - `ios-arm64-simulator`
  - `macos-arm64` (signed with Hardened Runtime)
- **`GLESv2.xcframework`** — libGLESv2, same three slices.

Each framework slice is:
- Signed with `Developer ID Application: Au-Zone Technologies Inc. (F39422DDCA)`
  (or ad-hoc if the cert is missing).
- Identified as `com.edgefirst.anglesdk.libEGL` / `com.edgefirst.anglesdk.libGLESv2`
  (not the upstream `org.chromium.ost.*`).
- Carrying a minimal `PrivacyInfo.xcprivacy` (no data collection).
- The macOS slice has Hardened Runtime enabled (notarization-ready).

## Prerequisites

```sh
# depot_tools on PATH (provides gn, ninja).
export PATH="$HOME/Software/Mobile/depot_tools:$PATH"

# ANGLE source synced (one-time, heavy).
cd ~/Software/Mobile/angle && gclient sync

# Developer ID cert in keychain (for signed builds).
# Falls back to ad-hoc signing with a warning if missing.
```

For notarization (optional but required for macOS distribution outside the App Store):

```sh
# One-time: store the App Store Connect API key in the keychain.
# Create the key at https://appstoreconnect.apple.com/access/integrations/api
# (App Manager access level), download the .p8, then:
xcrun notarytool store-credentials "angle-package" \
    --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUERID>
```

## Build

```sh
cd ~/Software/Mobile/angle-package

# Build + sign + package + verify all platforms:
make all

# Or one platform at a time:
make ios      # ios-device + ios-sim
make macos    # macos-arm64

# Re-verify without rebuilding:
make verify

# Clean build artifacts (keeps dist/):
make clean
```

## Notarize

After `make all`, submit the xcframeworks to Apple for notarization:

```sh
make notarize    # submits to notarytool, waits, staples (2–5 min)
```

This requires the `angle-package` notarytool keychain profile (see Prerequisites
above). The macOS slices are already signed with Hardened Runtime, so
notarization is the final step that makes `spctl assess` pass and allows
Gatekeeper to accept the frameworks without warnings.

## Versioning

ANGLE doesn't tag releases or use semantic versioning. Its version is the
**commit position** (`ANGLE_COMMIT_POSITION` = `git rev-list HEAD --count`),
which appears in the GL_VERSION string as `ANGLE 2.1.<position>` (e.g.
`ANGLE 2.1.28252`). The `2.1` is a legacy OpenGL ES conformance prefix that
never changes; the commit position is the real version number.

This project follows that scheme: releases are tagged `v<commit-position>`
(e.g. `v28252`). The version auto-derives from the ANGLE source checkout, so:

```sh
make publish              # auto-versions as v28252 (the current commit position)
make publish VER=v28252   # explicit (same thing)
make publish VER=v0.1.0   # override with a custom version if needed
```

To build from a specific ANGLE version, check out the desired commit or
`chromium/NNNN` branch in the `angle/` source tree before running `make`:

```sh
cd ~/Software/Mobile/angle
git checkout chromium/7930   # a specific Chromium milestone branch
# or: git checkout <commit-hash>
cd ~/Software/Mobile/angle-package
make release                 # publishes as v<that-commit's-position>
```

## Publish a release

After building + notarizing, publish a versioned GitHub release:

```sh
make publish              # auto-versioned (v<ANGLE-commit-position>)
make publish VER=v0.1.0   # explicit version
```

Or do everything in one shot:

```sh
make release              # build + sign + notarize + publish (auto-versioned)
```

This creates a git tag, pushes it, and uploads:
- `angle-xcframeworks-v<version>.zip` — the signed + notarized xcframeworks
- `angle-xcframeworks-v<version>.zip.sha256` — checksum for verification

Team members download the release and add the xcframeworks to their Xcode project.

## How a consumer uses the output

Add the xcframeworks to an Xcode project (or `project.yml` for XcodeGen):

```yaml
dependencies:
  - { framework: ../angle-package/dist/EGL.xcframework, embed: true }
  - { framework: ../angle-package/dist/GLESv2.xcframework, embed: true }
```

Xcode's "Embed & Sign" re-signs the iOS slices with the consuming app's team at
build time; the macOS slice's Developer ID signature + Hardened Runtime is
preserved for notarized macOS apps.

## Layout

```
angle-package/
├── config/          # GN args per slice + privacy manifest
├── scripts/         # build / sign / package / verify
├── build/           # intermediate per-slice outputs (gitignored)
└── dist/            # final signed xcframeworks + BUILD_INFO.txt (gitignored)
```

## Adding Android / Windows later

The structure separates config (what to build) from scripts (how to build):
- Android: add `config/gn-args-android.gnargs` + an Android packaging variant.
- Windows: add `config/gn-args-windows.gnargs` + a DLL/NuGet packaging variant.
No changes to the existing iOS/macOS paths.

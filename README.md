# angle-package

Standalone packaging layer for [ANGLE](https://chromium.googlesource.com/angle/angle)
(OpenGL ES over Metal/Vulkan/D3D), producing signed `.xcframework` packages
for iOS and macOS and a Direct3D 11 DLL package for Windows x64. Designed so
Android packaging can be added as a sibling target later.

Every slice is built from the ANGLE commit pinned in `config/angle.lock`, so
one release tag `v2.1.<commit-position>` names one source revision across the
Mac-built and Windows-built assets.

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

`dist-windows-x64/` (built on Windows, or by CI — see
[Windows x64](#windows-x64-direct3d-11)) contains the D3D11 package:

```
bin/libEGL.dll  bin/libGLESv2.dll           flat siblings: libEGL loads libGLESv2 from its own directory
lib/libEGL.dll.lib  lib/libGLESv2.dll.lib   import libraries
include/{EGL,GLES2,GLES3,KHR}/               ANGLE's public headers (incl. eglext_angle.h)
pdb/                                         symbols (released separately as -symbols.zip)
LICENSE  BUILD_INFO.txt
```

The DLLs link the static CRT (no VC++ redistributable) and depend only on
system DLLs (`d3d11`, `dxgi`, `d3dcompiler_47` from System32). They ship
unsigned unless a code-signing PFX is configured (see `scripts/sign-windows.ps1`).

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

This project follows ANGLE's own versioning scheme: **`v2.1.<commit-position>`**
(e.g. `v2.1.28252`). The commit position is `ANGLE_COMMIT_POSITION` =
`git rev-list HEAD --count`, which appears in the built binary's GL_VERSION
string as `OpenGL ES 3.0 (ANGLE 2.1.28252 ...)`. The `2.1` is a legacy OpenGL
ES conformance prefix that never changes; the commit position is the real
version number and increments monotonically with every ANGLE commit.

For packaging revisions within the same ANGLE commit (e.g. a signing fix or
build-config change without an ANGLE source update), append `-N`:
`v2.1.28252-1`, `v2.1.28252-2`, etc.

The version derives from the **pinned** ANGLE commit in `config/angle.lock`
(`scripts/angle-version.sh version`), not from whatever `../angle` happens to
have checked out. `build-slice.sh` refuses to build when the checkout is not at
the pin (`ANGLE_PIN_CHECK=0` bypasses it for experiments), and
`publish-release.sh` rejects a `VER` that does not match the pinned position:

```sh
make publish                  # auto: v2.1.28252
make publish VER=v2.1.28252   # explicit (same thing)
make publish VER=v2.1.28252-1 # packaging revision on the same ANGLE commit
```

To move to a new ANGLE version, check out the desired commit or
`chromium/NNNN` branch in the `angle/` source tree (a full-history checkout —
the commit position is `git rev-list HEAD --count`), re-pin, commit the lock,
then build and release:

```sh
cd ~/Software/Mobile/angle
git checkout chromium/7930   # a specific Chromium milestone branch
# or: git checkout <commit-hash>
gclient sync
cd ~/Software/Mobile/angle-package
make pin                     # rewrites config/angle.lock from ../angle
git commit -am "Pin ANGLE <sha> (position NNNNN)"
make release                 # publishes as v2.1.<pinned position>; the tag push
                             # triggers the Windows workflow for the same pin
```

## Publish a release

After building + notarizing, publish a versioned GitHub release:

```sh
make publish                    # auto-versioned (v2.1.<ANGLE-commit-position>)
make publish VER=v2.1.28252-1   # packaging revision
```

Or do everything in one shot:

```sh
make release                    # build + sign + notarize + publish (auto-versioned)
```

This creates a git tag, pushes it, and uploads (asset names carry the tag
verbatim, e.g. `angle-xcframeworks-v2.1.28252.zip`):
- `angle-xcframeworks-<tag>.zip` — the signed + notarized xcframeworks
- `angle-xcframeworks-<tag>.zip.sha256` — checksum for verification

Pushing the tag triggers `.github/workflows/windows.yml`, which builds the same
pinned commit on a `windows-2025` runner and adds to the **same** release:
- `angle-windows-x64-<tag>.zip` — `bin/` DLLs, `lib/` import libs, `include/`, `LICENSE`, `BUILD_INFO.txt`
- `angle-windows-x64-<tag>.zip.sha256`
- `angle-windows-x64-<tag>-symbols.zip` (+ `.sha256`) — PDBs

Either side may publish first: `scripts/gh-release-upload.sh` creates the
release as a draft when it does not exist yet and otherwise uploads with
`--clobber`, appending its `BUILD_INFO.txt` to the notes.

Team members download the release and add the xcframeworks to their Xcode
project, or extract the Windows zip next to their executable.

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

On Windows, extract `angle-windows-x64-<tag>.zip` and either place
`bin\libEGL.dll` + `bin\libGLESv2.dll` next to the executable (or the loading
DLL) or point the consumer at `bin\` (the EdgeFirst HAL reads
`EDGEFIRST_ANGLE_PATH`). Load `libEGL.dll` by absolute path with
`LoadLibraryEx(..., LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)`
so it can find its sibling `libGLESv2.dll`; everything else resolves from
System32. Bring up the display with
`eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE, EGL_NONE})`
(add `EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_DEVICE_TYPE_D3D_WARP_ANGLE`
for a GPU-less host). `scripts/windows/angle_probe.c` is a complete example.
Verify a download with `gh attestation verify <zip> --repo EdgeFirstAI/angle-package`.

## Windows x64 (Direct3D 11)

The Windows slice is produced by `.github/workflows/windows.yml` on a pinned
`windows-2025` runner (Visual Studio 2022 + Windows SDK, VS is only used for
CRT headers/libs — ANGLE builds with its own clang-cl/lld-link). It runs on
every `v2.1.*` tag push, and on demand:

```sh
gh workflow run windows.yml -f publish=false              # dry run: artifact only
gh workflow run windows.yml -f tag=v2.1.28252 -f publish=true   # add to an existing release
```

The workflow checks that the tag matches the pinned position, clones ANGLE with
full history at the pinned commit (a shallow clone would bake a wrong commit
position into `GL_VERSION`), syncs with the OpenCL and Dawn dependencies
skipped, builds `libEGL` + `libGLESv2`, verifies the package (import allowlist,
Authenticode status, a WARP runtime probe that asserts `ANGLE 2.1.<position>`),
zips it, attests provenance, and uploads via `scripts/gh-release-upload.sh`.
Signing is optional: set the `WINDOWS_CODESIGN_PFX_BASE64` and
`WINDOWS_CODESIGN_PFX_PASSWORD` repository secrets to enable it.

### Building locally on Windows

Needs PowerShell 7, Git (with `core.longpaths=true`), Visual Studio 2022 or
2026 with the C++ desktop workload and a Windows 11 SDK that includes the
Debugging Tools (`Debuggers\x64\dbghelp.dll` — Chromium's `gn gen` copies it),
plus depot_tools and an ANGLE checkout as siblings of this repo:

```powershell
git config --global core.longpaths true
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git ..\depot_tools
git clone https://chromium.googlesource.com/angle/angle.git ..\angle     # full history
git -C ..\angle checkout --detach <ANGLE_COMMIT from config\angle.lock>
# .gclient (managed: False; custom_vars checkout_angle_cl_deps / checkout_angle_dawn_deps = False)
$env:PATH = "$(Resolve-Path ..\depot_tools);$env:PATH"; $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
..\depot_tools\bootstrap\win_tools.bat      # once: fetches depot_tools' bundled git/python
Set-Location ..\angle; gclient sync -D --no-history -j8; Set-Location ..\angle-package

pwsh -File scripts\build-windows.ps1        # gn gen + ninja libEGL libGLESv2 -> build\windows-x64\
pwsh -File scripts\assemble-windows.ps1     # -> dist-windows-x64\
pwsh -File scripts\verify-windows.ps1       # hardware D3D11 probe; -Warp for a GPU-less host
pwsh -File scripts\package-windows.ps1      # -> build\angle-windows-x64-<tag>.zip (+ symbols)
```

`make windows` / `make verify-windows` / `make publish-windows` wrap the same
scripts (GNU make from Git Bash or `winget install GnuWin32.Make`). If Chromium's
`build/vs_toolchain.py` at the pinned revision does not list your Visual Studio
major, set `GYP_MSVS_VERSION=2022` and `vs2022_install=<path>` (VS 2022 Build
Tools can be installed side by side).

## Layout

```
angle-package/
├── config/            # GN args per slice, angle.lock (ANGLE pin), privacy manifest
├── scripts/           # build / sign / package / verify (bash for Apple + shared, pwsh for Windows)
├── .github/workflows/ # windows.yml — Windows x64 build + publish
├── build/             # intermediate per-slice outputs (gitignored)
├── dist/              # final signed xcframeworks + BUILD_INFO.txt (gitignored)
└── dist-windows-x64/  # Windows package layout + BUILD_INFO.txt (gitignored)
```

## Adding Android later

The structure separates config (what to build) from scripts (how to build):
add `config/gn-args-android.gnargs` + an Android packaging variant. No changes
to the existing iOS/macOS/Windows paths.

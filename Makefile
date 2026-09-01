# angle-package — build signed + notarized ANGLE xcframeworks for iOS + macOS.
#
# Usage:
#   make all           # build + sign + package + verify all slices
#   make ios           # build ios-device + ios-sim slices only
#   make macos         # build macos-arm64 slice only
#   make notarize      # notarize dist/ via Apple's notarytool (requires keychain profile)
#   make publish       # publish a GitHub release (auto-versioned v2.1.<commit-position>)
#   make publish VER=v2.1.28252-1  # publish with explicit version
#   make release       # all: build + notarize + publish
#   make verify        # re-verify dist/ without rebuilding
#   make clean         # remove build/, dist/ and dist-windows-x64/
#
# Windows x64 (Direct3D 11) — run on a Windows box (pwsh 7) or let CI do it:
#   make pin           # (any machine with ../angle) write config/angle.lock from the checkout
#   make windows       # build + assemble + verify dist-windows-x64/ (needs depot_tools + ANGLE synced)
#   make verify-windows
#   make publish-windows  # zip + upload to the release tag (CI is the publisher of record)
#
# Prerequisites: depot_tools on PATH, ANGLE synced at the pinned commit
# (config/angle.lock), Developer ID cert in keychain.
# For notarize: keychain profile "angle-package" (xcrun notarytool store-credentials).
# For publish: gh CLI authenticated.

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
PWSH ?= pwsh -NoProfile -ExecutionPolicy Bypass
# Release tag: VER on the command line, else v2.1.<position> from config/angle.lock.
TAG = $(or $(VER),$(shell bash $(ROOT)scripts/angle-version.sh version))

.PHONY: all ios macos notarize publish release verify clean \
        pin windows verify-windows publish-windows

all: ios macos
	@bash $(ROOT)scripts/assemble-xcframework.sh
	@bash $(ROOT)scripts/verify.sh

ios:
	@bash $(ROOT)scripts/build-slice.sh ios-device
	@bash $(ROOT)scripts/build-slice.sh ios-sim

macos:
	@bash $(ROOT)scripts/build-slice.sh macos

notarize:
	@bash $(ROOT)scripts/notarize.sh

publish:
	@bash $(ROOT)scripts/publish-release.sh $(VER)

release:
	@$(MAKE) all
	@$(MAKE) notarize
	@bash $(ROOT)scripts/publish-release.sh $(VER)

verify:
	@bash $(ROOT)scripts/verify.sh

pin:
	@bash $(ROOT)scripts/angle-version.sh write

windows:
	@$(PWSH) -File $(ROOT)scripts/build-windows.ps1
	@$(PWSH) -File $(ROOT)scripts/assemble-windows.ps1 -Tag $(TAG)
	@$(PWSH) -File $(ROOT)scripts/verify-windows.ps1

verify-windows:
	@$(PWSH) -File $(ROOT)scripts/verify-windows.ps1

publish-windows:
	@$(PWSH) -File $(ROOT)scripts/package-windows.ps1 -Tag $(TAG)
	@bash $(ROOT)scripts/gh-release-upload.sh $(TAG) --title "ANGLE $(TAG)" \
	    --notes-file $(ROOT)dist-windows-x64/BUILD_INFO.txt -- \
	    $(ROOT)build/angle-windows-x64-$(TAG).zip \
	    $(ROOT)build/angle-windows-x64-$(TAG).zip.sha256 \
	    $(ROOT)build/angle-windows-x64-$(TAG)-symbols.zip \
	    $(ROOT)build/angle-windows-x64-$(TAG)-symbols.zip.sha256

clean:
	rm -rf $(ROOT)build $(ROOT)dist $(ROOT)dist-windows-x64

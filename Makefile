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
#   make clean         # remove build/ and dist/
#
# Prerequisites: depot_tools on PATH, ANGLE synced, Developer ID cert in keychain.
# For notarize: keychain profile "angle-package" (xcrun notarytool store-credentials).
# For publish: gh CLI authenticated.

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: all ios macos notarize publish release verify clean

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

clean:
	rm -rf $(ROOT)build $(ROOT)dist

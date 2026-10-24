# Shortcuts for the commands described in README.md ("Development") and docs/project_plan.md.
# Run `make` or `make help` to list the targets.
#
# Flutter runs through FVM (the version is pinned in .fvmrc) when fvm is installed; override with
#   make test FLUTTER=flutter
# Nothing here publishes or changes remote state: `publish-dry-run` is the only publish target.

SHELL := /bin/bash
.DEFAULT_GOAL := help

FLUTTER   ?= $(if $(shell command -v fvm 2>/dev/null),fvm flutter,flutter)
DART      ?= $(if $(shell command -v fvm 2>/dev/null),fvm dart,dart)
PLATFORMS ?=
DEVICE    ?= macos

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Variables: FLUTTER=$(FLUTTER)  PLATFORMS='macos ios android windows' (fetch-prebuilt)  DEVICE=$(DEVICE) (integration-test)"

# ---------------------------------------------------------------------------------------------
# Daily checks
# ---------------------------------------------------------------------------------------------

.PHONY: setup format format-check analyze test check ci act

setup: ## flutter pub get (package and example app)
	$(FLUTTER) pub get
	cd example && $(FLUTTER) pub get

format: ## Format all Dart code
	$(DART) format .

format-check: ## Fail if any Dart file is not formatted (same as CI)
	$(DART) format --output=none --set-exit-if-changed .

analyze: ## flutter analyze
	$(FLUTTER) analyze

test: ## flutter test
	$(FLUTTER) test

check: format-check analyze test ## Run the same checks as CI, natively (fast)

ci: setup check ## setup + check; the CI job without Docker

act: ## Run .github/workflows/ci.yml locally in Docker with act
	act pull_request -W .github/workflows/ci.yml -j ci

# ---------------------------------------------------------------------------------------------
# Prebuilt FFmpeg / LAME libraries
# ---------------------------------------------------------------------------------------------

.PHONY: fetch-prebuilt fetch-sources build-macos package-macos build-ios package-ios build-android build-windows prebuilt-macos prebuilt-ios

fetch-prebuilt: ## Download the prebuilt libraries (PLATFORMS="macos ios android windows", default all)
	tool/fetch_prebuilt.sh $(PLATFORMS)

fetch-sources: ## Download and verify the pinned FFmpeg and LAME sources
	build/ffmpeg/fetch_sources.sh

build-macos: ## Build universal macOS dylibs into build/work/out/macos
	build/ffmpeg/build_macos.sh

package-macos: ## Create macos/Frameworks/*.xcframework and prebuilt/include
	build/ffmpeg/package_macos.sh

build-ios: ## Build iOS dylibs (device and simulator)
	build/ffmpeg/build_ios.sh

package-ios: ## Create the iOS xcframeworks
	build/ffmpeg/package_ios.sh

build-android: ## Build Android shared libraries into android/src/main/jniLibs (needs the NDK)
	build/ffmpeg/build_android.sh

build-windows: ## Build Windows DLLs (run inside MSYS2)
	build/ffmpeg/build_windows.sh

prebuilt-macos: fetch-sources build-macos package-macos ## Build macOS libraries from source, end to end

prebuilt-ios: fetch-sources build-ios package-ios ## Build iOS libraries from source, end to end

# ---------------------------------------------------------------------------------------------
# Native tests and fixtures (macOS)
# ---------------------------------------------------------------------------------------------

.PHONY: native-test native-test-leaks fixtures

native-test: ## Native C tests with ASan and UBSan (needs build-macos and package-macos)
	tool/run_native_tests_macos.sh

native-test-leaks: ## Native C tests with the macOS leak check
	tool/run_native_tests_macos.sh --leaks

fixtures: ## Regenerate example/assets/fixtures/tone.* (needs build-macos and package-macos)
	tool/make_fixtures_macos.sh

# ---------------------------------------------------------------------------------------------
# Example app and release checks
# ---------------------------------------------------------------------------------------------

.PHONY: integration-test example-macos example-ios example-apk publish-dry-run clean

integration-test: ## Integration tests on a device (DEVICE=macos|<device id>)
	cd example && $(FLUTTER) test integration_test -d $(DEVICE)

example-macos: ## Build the example app for macOS
	cd example && $(FLUTTER) build macos

example-ios: ## Build the example app for iOS (no code signing)
	cd example && $(FLUTTER) build ios --no-codesign

example-apk: ## Build the example app for Android (debug APK)
	cd example && $(FLUTTER) build apk --debug

publish-dry-run: ## flutter pub publish --dry-run (run fetch-prebuilt first; expect 0 warnings)
	$(FLUTTER) pub publish --dry-run

clean: ## flutter clean (package and example app); keeps prebuilt libraries and build/ffmpeg
	$(FLUTTER) clean
	cd example && $(FLUTTER) clean

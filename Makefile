.PHONY: all engine core project mac ios test run-mac clean

DD := build/dd

all: engine core project mac ios

engine:            ## Bundle the tscircuit packages into app/Shared/Resources/engine.js
	cd engine && bun install && bun build.ts

core:              ## Build the Rust core XCFramework, Swift bindings and MCP helper
	./scripts/build-xcframework.sh

project:           ## Generate app/Traces.xcodeproj
	cd app && xcodegen

mac: project
	xcodebuild -project app/Traces.xcodeproj -scheme Traces-Mac -configuration Debug -derivedDataPath $(DD) build

ios: project
	xcodebuild -project app/Traces.xcodeproj -scheme Traces-iOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath $(DD) build

test:              ## Rust unit + integration tests, and an engine smoke compile
	cargo test -p traceworks-core
	cd engine && bun test-engine.ts ../templates/esp32-s3-devboard

run-mac: mac
	open $(DD)/Build/Products/Debug/Traces.app

clean:
	rm -rf build target app/Traces.xcodeproj

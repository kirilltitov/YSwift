# YSwift build orchestration.

.PHONY: all build test fixtures lint format clean

SWIFT_SOURCES := Sources Tests Package.swift

all: build

## build: build the Swift package
build:
	swift build

## test: run the full Swift conformance suite
test:
	swift test

## fixtures: regenerate golden vectors from pinned JS-Yjs
fixtures:
	cd fixtures && npm ci && npm run generate

## lint: check formatting/style with swift-format (no changes)
lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

## format: apply swift-format in place
format:
	swift format --in-place --recursive $(SWIFT_SOURCES)

## clean: remove Swift build products
clean:
	swift package clean

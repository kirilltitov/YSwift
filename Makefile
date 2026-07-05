# YSwift build orchestration.
#
# The Swift package links a Rust static library (rust/cyrs, a C-ABI facade over
# yrs), so that staticlib must be built before Swift. These targets chain it.

.PHONY: all build test rust rust-test fixtures lint format clean

SWIFT_SOURCES := Sources Tests Package.swift

CYRS_DIR := rust/cyrs

# Homebrew rustup keeps the toolchain binaries off PATH, and calling cargo by its
# absolute path makes it fail to find rustc. Prepend the active toolchain's bin
# dir to PATH for every recipe so plain `cargo` (and `rustc`) resolve.
RUSTUP := $(shell command -v rustup 2>/dev/null || echo /opt/homebrew/bin/rustup)
TOOLCHAIN_BIN := $(shell $(RUSTUP) which cargo 2>/dev/null | xargs dirname)
export PATH := $(TOOLCHAIN_BIN):$(PATH)

all: build

## rust: build the cyrs staticlib (libcyrs.a)
rust:
	cd $(CYRS_DIR) && cargo build --release

## rust-test: cross-check yrs against the golden vectors
rust-test:
	cd $(CYRS_DIR) && cargo test

## build: staticlib + swift build
build: rust
	swift build

## test: staticlib + full Swift conformance suite
test: rust
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

## clean: remove Swift and Rust build products
clean:
	swift package clean
	cd $(CYRS_DIR) && cargo clean

//! `cyrs` — a thin C ABI over the Rust `yrs` CRDT, backing YSwift's Phase-1
//! engine (`YrsEngine`).
//!
//! The `extern "C"` surface is added incrementally (doc/text/transaction/encode
//! first). For now this crate exists so we can (a) validate `yrs` reproduces the
//! JS-Yjs golden vectors byte-for-byte (see `tests/golden.rs`) before wiring FFI,
//! and (b) produce the `libcyrs.a` staticlib Swift will link.
//!
//! Key compatibility setting: documents are created with
//! `OffsetKind::Utf16` so item lengths match Yjs's UTF-16 code-unit model on the
//! wire. See DECISIONS.md.

/// Crate marker; real FFI entry points land next.
pub const CYRS_VERSION: &str = env!("CARGO_PKG_VERSION");

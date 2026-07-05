//! `cyrs` — a thin C ABI over the Rust `yrs` CRDT, backing YSwift's Phase-1
//! engine (`YrsEngine`).
//!
//! Design notes:
//! - Documents use `OffsetKind::Utf16` so item lengths match Yjs's UTF-16
//!   code-unit model on the wire (validated in `tests/golden.rs`).
//! - Only the v1 update/state-vector format is exposed (requirements §9.2).
//! - Text types are resolved by name **through the active transaction**
//!   (`TransactionMut::get_or_insert_text`). Resolving via the `Doc` instead
//!   would open a nested transaction and deadlock on the store lock.
//! - Opaque pointers (`Doc`, `TransactionMut`) are boxed and owned by the
//!   caller. Transaction lifetimes are erased to `'static`; the Swift side
//!   guarantees a transaction never outlives its document and that at most one
//!   write transaction is live per document (serialized by a `Mutex`).
//! - Byte buffers returned to the caller must be freed with `ybytes_free`.
//! - Formatting attributes cross the boundary as a JSON object (UTF-8).

#![allow(clippy::missing_safety_doc)]

use serde_json::Value;
use std::sync::Arc;
use yrs::types::Attrs;
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{
    Any, ClientID, Doc, GetString, OffsetKind, Options, ReadTxn, StateVector, Text, Transact,
    TransactionMut, Update, WriteTxn,
};

pub const CYRS_VERSION: &str = env!("CARGO_PKG_VERSION");

// ---- helpers ----------------------------------------------------------------

unsafe fn as_slice<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

unsafe fn as_str<'a>(ptr: *const u8, len: usize) -> &'a str {
    std::str::from_utf8(as_slice(ptr, len)).unwrap_or("")
}

/// Transfers ownership of `bytes` to the caller; writes its length to `out_len`.
/// Caller must release it with `ybytes_free`.
unsafe fn bytes_out(bytes: Vec<u8>, out_len: *mut usize) -> *mut u8 {
    let boxed = bytes.into_boxed_slice();
    *out_len = boxed.len();
    Box::into_raw(boxed) as *mut u8
}

fn attrs_from_json(bytes: &[u8]) -> Attrs {
    let mut attrs = Attrs::new();
    let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(bytes) else {
        return attrs;
    };
    for (k, v) in obj {
        let any = match v {
            Value::Bool(b) => Any::from(b),
            Value::String(s) => Any::String(Arc::from(s.as_str())),
            Value::Number(n) if n.is_i64() => Any::BigInt(n.as_i64().unwrap()),
            Value::Number(n) => Any::Number(n.as_f64().unwrap()),
            Value::Null => Any::Null,
            _ => continue,
        };
        attrs.insert(Arc::from(k.as_str()), any);
    }
    attrs
}

// ---- Doc --------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn ydoc_new(client_id: u64, skip_gc: bool) -> *mut Doc {
    let doc = Doc::with_options(Options {
        client_id: ClientID::new(client_id),
        offset_kind: OffsetKind::Utf16,
        skip_gc,
        ..Default::default()
    });
    Box::into_raw(Box::new(doc))
}

#[no_mangle]
pub unsafe extern "C" fn ydoc_client_id(doc: *mut Doc) -> u64 {
    (*doc).client_id().get()
}

#[no_mangle]
pub unsafe extern "C" fn ydoc_destroy(doc: *mut Doc) {
    if !doc.is_null() {
        drop(Box::from_raw(doc));
    }
}

// ---- Transaction (write; also used for reads) -------------------------------

#[no_mangle]
pub unsafe extern "C" fn ytxn(doc: *mut Doc) -> *mut TransactionMut<'static> {
    // Lifetime erasure: the Swift side guarantees the txn does not outlive `doc`.
    let txn: TransactionMut<'static> = std::mem::transmute((*doc).transact_mut());
    Box::into_raw(Box::new(txn))
}

#[no_mangle]
pub unsafe extern "C" fn ytxn_commit(txn: *mut TransactionMut<'static>) {
    if !txn.is_null() {
        drop(Box::from_raw(txn)); // commit happens on drop
    }
}

// ---- Text operations (text resolved by name via the active transaction) -----

#[no_mangle]
pub unsafe extern "C" fn ytext_insert(
    txn: *mut TransactionMut<'static>,
    name: *const u8,
    name_len: usize,
    index: u32,
    s: *const u8,
    s_len: usize,
) {
    let txn = &mut *txn;
    let text = txn.get_or_insert_text(as_str(name, name_len));
    text.insert(txn, index, as_str(s, s_len));
}

#[no_mangle]
pub unsafe extern "C" fn ytext_insert_attrs(
    txn: *mut TransactionMut<'static>,
    name: *const u8,
    name_len: usize,
    index: u32,
    s: *const u8,
    s_len: usize,
    attrs: *const u8,
    attrs_len: usize,
) {
    let txn = &mut *txn;
    let text = txn.get_or_insert_text(as_str(name, name_len));
    text.insert_with_attributes(txn, index, as_str(s, s_len), attrs_from_json(as_slice(attrs, attrs_len)));
}

#[no_mangle]
pub unsafe extern "C" fn ytext_remove(
    txn: *mut TransactionMut<'static>,
    name: *const u8,
    name_len: usize,
    index: u32,
    len: u32,
) {
    let txn = &mut *txn;
    let text = txn.get_or_insert_text(as_str(name, name_len));
    text.remove_range(txn, index, len);
}

#[no_mangle]
pub unsafe extern "C" fn ytext_format(
    txn: *mut TransactionMut<'static>,
    name: *const u8,
    name_len: usize,
    index: u32,
    len: u32,
    attrs: *const u8,
    attrs_len: usize,
) {
    let txn = &mut *txn;
    let text = txn.get_or_insert_text(as_str(name, name_len));
    text.format(txn, index, len, attrs_from_json(as_slice(attrs, attrs_len)));
}

#[no_mangle]
pub unsafe extern "C" fn ytext_string(
    txn: *mut TransactionMut<'static>,
    name: *const u8,
    name_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let txn = &mut *txn;
    let text = txn.get_or_insert_text(as_str(name, name_len));
    bytes_out(text.get_string(&*txn).into_bytes(), out_len)
}

#[no_mangle]
pub unsafe extern "C" fn ytext_len(
    txn: *mut TransactionMut<'static>,
    name: *const u8,
    name_len: usize,
) -> u32 {
    let txn = &mut *txn;
    let text = txn.get_or_insert_text(as_str(name, name_len));
    text.len(&*txn)
}

// ---- Encoding & sync (v1) ---------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn ytxn_state_as_update_v1(
    txn: *mut TransactionMut<'static>,
    sv: *const u8,
    sv_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let state_vector = if sv.is_null() {
        StateVector::default()
    } else {
        StateVector::decode_v1(as_slice(sv, sv_len)).unwrap_or_default()
    };
    bytes_out((*txn).encode_state_as_update_v1(&state_vector), out_len)
}

#[no_mangle]
pub unsafe extern "C" fn ytxn_state_vector_v1(
    txn: *mut TransactionMut<'static>,
    out_len: *mut usize,
) -> *mut u8 {
    bytes_out((*txn).state_vector().encode_v1(), out_len)
}

/// Applies a v1 update. Returns `false` if the bytes could not be decoded/applied.
#[no_mangle]
pub unsafe extern "C" fn ytxn_apply_update_v1(
    txn: *mut TransactionMut<'static>,
    update: *const u8,
    len: usize,
) -> bool {
    match Update::decode_v1(as_slice(update, len)) {
        Ok(u) => (*txn).apply_update(u).is_ok(),
        Err(_) => false,
    }
}

// ---- Memory -----------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn ybytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
    }
}

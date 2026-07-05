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
use std::ffi::c_void;
use std::sync::Arc;
use yrs::types::text::YChange;
use yrs::types::Attrs;
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{
    Any, ClientID, Doc, GetString, OffsetKind, Options, Origin, Out, ReadTxn, StateVector,
    Subscription, Text, Transact, TransactionMut, Update, UpdateEvent, WriteTxn,
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

/// Converts a yrs `Any` into a serde_json `Value` for delta serialization.
fn any_to_value(a: &Any) -> Value {
    match a {
        Any::Null | Any::Undefined => Value::Null,
        Any::Bool(b) => Value::Bool(*b),
        Any::Number(n) => serde_json::Number::from_f64(*n).map(Value::Number).unwrap_or(Value::Null),
        Any::BigInt(i) => Value::Number((*i).into()),
        Any::String(s) => Value::String(s.to_string()),
        Any::Buffer(_) => Value::Null, // binary embeds are out of scope for text materialization
        Any::Array(arr) => Value::Array(arr.iter().map(any_to_value).collect()),
        Any::Map(m) => Value::Object(m.iter().map(|(k, v)| (k.clone(), any_to_value(v))).collect()),
    }
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

/// Returns the text content as a Yjs-style delta, serialized as a JSON array of
/// `{ "insert": <value>, "attributes"?: {..} }` ops (UTF-8). Free with ybytes_free.
#[no_mangle]
pub unsafe extern "C" fn ytext_delta(
    txn: *mut TransactionMut<'static>,
    name: *const u8,
    name_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let txn = &mut *txn;
    let text = txn.get_or_insert_text(as_str(name, name_len));
    let mut ops: Vec<Value> = Vec::new();
    for d in text.diff(&*txn, YChange::identity) {
        let insert = match &d.insert {
            Out::Any(a) => any_to_value(a),
            _ => Value::Null, // shared-type embeds: out of scope for text materialization
        };
        let mut op = serde_json::Map::new();
        op.insert("insert".to_string(), insert);
        if let Some(attrs) = &d.attributes {
            let mut m = serde_json::Map::new();
            for (k, v) in attrs.iter() {
                m.insert(k.to_string(), any_to_value(v));
            }
            op.insert("attributes".to_string(), Value::Object(m));
        }
        ops.push(Value::Object(op));
    }
    bytes_out(serde_json::to_vec(&Value::Array(ops)).unwrap_or_default(), out_len)
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

// ---- Update observers & transaction origin ----------------------------------

/// C callback: (user_data, origin_ptr, origin_len, update_ptr, update_len).
/// `origin_ptr` is null / `origin_len` 0 when the transaction had no origin.
/// All buffers are valid only for the duration of the call.
pub type YUpdateCallback = extern "C" fn(*mut c_void, *const u8, usize, *const u8, usize);

/// Subscribes to v1 update events. Returns an opaque subscription (null on
/// error). Must be called with NO live transaction on `doc` (uses try_write).
#[no_mangle]
pub unsafe extern "C" fn ydoc_observe_update_v1(
    doc: *mut Doc,
    cb: YUpdateCallback,
    user_data: *mut c_void,
) -> *mut Subscription {
    // Carry the pointer as usize so the 'static + Send + Sync closure is happy.
    let ud = user_data as usize;
    let result = (*doc).observe_update_v1(move |txn: &TransactionMut, e: &UpdateEvent| {
        let (o_ptr, o_len) = match txn.origin() {
            Some(o) => {
                let s = o.as_ref();
                (s.as_ptr(), s.len())
            }
            None => (std::ptr::null(), 0usize),
        };
        cb(ud as *mut c_void, o_ptr, o_len, e.update.as_ptr(), e.update.len());
    });
    match result {
        Ok(sub) => Box::into_raw(Box::new(sub)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Drops a subscription (unsubscribes the callback).
#[no_mangle]
pub unsafe extern "C" fn ysubscription_free(sub: *mut Subscription) {
    if !sub.is_null() {
        drop(Box::from_raw(sub));
    }
}

/// Like `ytxn` but tags the write transaction with an origin (bytes are copied).
#[no_mangle]
pub unsafe extern "C" fn ytxn_with_origin(
    doc: *mut Doc,
    origin: *const u8,
    origin_len: usize,
) -> *mut TransactionMut<'static> {
    let o = Origin::from(as_slice(origin, origin_len));
    let txn: TransactionMut<'static> = std::mem::transmute((*doc).transact_mut_with(o));
    Box::into_raw(Box::new(txn))
}

// ---- Memory -----------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn ybytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
    }
}

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
use yrs::sync::{Awareness, AwarenessUpdate};
use yrs::types::text::YChange;
use yrs::types::Attrs;
use yrs::types::Delta;
use yrs::undo::{Options as UndoOptions, UndoManager};
use yrs::updates::decoder::{Decode, Decoder, DecoderV1};
use yrs::updates::encoder::Encode;
use yrs::{
    diff_updates_v1, merge_updates_v1, Any, Assoc, ClientID, Doc, GetString, IndexedSequence,
    Observable, OffsetKind, Options, Origin, Out, ReadTxn, StateVector, StickyIndex, Subscription,
    Text, Transact, TransactionMut, Update, UpdateEvent, WriteTxn,
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

/// Converts a yrs `Attrs` map into a serde_json object.
fn attrs_to_value(attrs: &Attrs) -> Value {
    Value::Object(attrs.iter().map(|(k, v)| (k.to_string(), any_to_value(v))).collect())
}

/// Serializes a text delta (`&[Delta]`) into a Yjs-style JSON op array.
fn delta_to_json(delta: &[Delta]) -> Vec<u8> {
    let mut ops: Vec<Value> = Vec::new();
    for d in delta {
        let mut op = serde_json::Map::new();
        match d {
            Delta::Inserted(value, attrs) => {
                let insert = match value {
                    Out::Any(a) => any_to_value(a),
                    _ => Value::Null,
                };
                op.insert("insert".to_string(), insert);
                if let Some(attrs) = attrs {
                    op.insert("attributes".to_string(), attrs_to_value(attrs));
                }
            }
            Delta::Retain(n, attrs) => {
                op.insert("retain".to_string(), Value::Number((*n as u64).into()));
                if let Some(attrs) = attrs {
                    op.insert("attributes".to_string(), attrs_to_value(attrs));
                }
            }
            Delta::Deleted(n) => {
                op.insert("delete".to_string(), Value::Number((*n as u64).into()));
            }
        }
        ops.push(Value::Object(op));
    }
    serde_json::to_vec(&Value::Array(ops)).unwrap_or_default()
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

/// C callback: (user_data, delta_json_ptr, delta_json_len). Buffer is call-scoped.
pub type YTextObserverCallback = extern "C" fn(*mut c_void, *const u8, usize);

/// Observes changes to the named text; the callback receives the change as a
/// Yjs-style JSON delta array. Register with no live transaction.
#[no_mangle]
pub unsafe extern "C" fn ytext_observe(
    doc: *mut Doc,
    name: *const u8,
    name_len: usize,
    cb: YTextObserverCallback,
    user_data: *mut c_void,
) -> *mut Subscription {
    let text = (*doc).get_or_insert_text(as_str(name, name_len));
    let ud = user_data as usize;
    let sub = text.observe(move |txn, e| {
        let json = delta_to_json(e.delta(txn));
        cb(ud as *mut c_void, json.as_ptr(), json.len());
    });
    Box::into_raw(Box::new(sub))
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
/// An apply error may occur after a valid prefix was integrated; callers must
/// discard the document after `false` rather than continue using its state.
#[no_mangle]
pub unsafe extern "C" fn ytxn_apply_update_v1(
    txn: *mut TransactionMut<'static>,
    update: *const u8,
    len: usize,
) -> bool {
    let mut decoder = DecoderV1::from(as_slice(update, len));
    let Ok(decoded) = Update::decode(&mut decoder) else {
        return false;
    };
    let Ok(trailing) = decoder.read_to_end() else {
        return false;
    };
    trailing.is_empty() && (*txn).apply_update(decoded).is_ok()
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

// ---- Doc-less update ops ----------------------------------------------------

/// Merges v1 updates (concatenated into `concat`, split by `lens`) into one v1
/// update. Returns null on decode error.
#[no_mangle]
pub unsafe extern "C" fn ymerge_updates_v1(
    concat: *const u8,
    concat_len: usize,
    lens: *const usize,
    count: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let data = as_slice(concat, concat_len);
    let lens = if lens.is_null() || count == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(lens, count)
    };
    let mut updates: Vec<&[u8]> = Vec::with_capacity(count);
    let mut off = 0usize;
    for &l in lens {
        if off + l > data.len() {
            *out_len = 0;
            return std::ptr::null_mut();
        }
        updates.push(&data[off..off + l]);
        off += l;
    }
    match merge_updates_v1(updates) {
        Ok(v) => bytes_out(v, out_len),
        Err(_) => {
            *out_len = 0;
            std::ptr::null_mut()
        }
    }
}

/// Returns the part of `update` missing from a peer at `state_vector` (v1).
#[no_mangle]
pub unsafe extern "C" fn ydiff_update_v1(
    update: *const u8,
    update_len: usize,
    sv: *const u8,
    sv_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    match diff_updates_v1(as_slice(update, update_len), as_slice(sv, sv_len)) {
        Ok(v) => bytes_out(v, out_len),
        Err(_) => {
            *out_len = 0;
            std::ptr::null_mut()
        }
    }
}

// ---- Sticky index (relative position) --------------------------------------

/// Creates a sticky index at `index` in the named text (assoc: 0 = after, <0 =
/// before) and returns its v1 encoding (yjs relative-position compatible). Null
/// if the index is out of range.
#[no_mangle]
pub unsafe extern "C" fn ysticky_from_index(
    txn: *mut TransactionMut<'static>,
    name: *const u8,
    name_len: usize,
    index: u32,
    assoc: i8,
    out_len: *mut usize,
) -> *mut u8 {
    let txn = &mut *txn;
    let text = txn.get_or_insert_text(as_str(name, name_len));
    let assoc = if assoc < 0 { Assoc::Before } else { Assoc::After };
    match text.sticky_index(&*txn, index, assoc) {
        Some(sticky) => bytes_out(sticky.encode_v1(), out_len),
        None => {
            *out_len = 0;
            std::ptr::null_mut()
        }
    }
}

/// Resolves a v1-encoded sticky index to an absolute index in the txn's doc.
/// Returns -1 if it cannot be decoded or referenced.
#[no_mangle]
pub unsafe extern "C" fn ysticky_to_index(
    txn: *mut TransactionMut<'static>,
    sticky: *const u8,
    sticky_len: usize,
) -> i64 {
    let txn = &mut *txn;
    match StickyIndex::decode_v1(as_slice(sticky, sticky_len)) {
        Ok(s) => match s.get_offset(&*txn) {
            Some(off) => off.index as i64,
            None => -1,
        },
        Err(_) => -1,
    }
}

// ---- Awareness (ephemeral presence; y-protocols/awareness compatible) -------
// Awareness methods take &mut / rely on interior state; the Swift side serializes
// all calls to a given awareness with its own lock.

#[no_mangle]
pub unsafe extern "C" fn ysync_awareness_new(doc: *mut Doc) -> *mut Awareness {
    Box::into_raw(Box::new(Awareness::new((*doc).clone())))
}

#[no_mangle]
pub unsafe extern "C" fn ysync_awareness_free(aw: *mut Awareness) {
    if !aw.is_null() {
        drop(Box::from_raw(aw));
    }
}

#[no_mangle]
pub unsafe extern "C" fn ysync_awareness_client_id(aw: *mut Awareness) -> u64 {
    (*aw).client_id().get()
}

#[no_mangle]
pub unsafe extern "C" fn ysync_set_local_state(aw: *mut Awareness, json: *const u8, json_len: usize) {
    (*aw).set_local_state_raw(as_str(json, json_len));
}

#[no_mangle]
pub unsafe extern "C" fn ysync_clean_local_state(aw: *mut Awareness) {
    (*aw).clean_local_state();
}

#[no_mangle]
pub unsafe extern "C" fn ysync_remove_state(aw: *mut Awareness, client_id: u64) {
    (*aw).remove_state(ClientID::new(client_id));
}

/// All known client states as a JSON object `{ "<clientId>": <state>, .. }`.
#[no_mangle]
pub unsafe extern "C" fn ysync_states(aw: *mut Awareness, out_len: *mut usize) -> *mut u8 {
    let aw = &*aw;
    let ids: Vec<_> = aw.iter().map(|(id, _)| id).collect();
    let mut map = serde_json::Map::new();
    for id in ids {
        if let Some(val) = aw.state::<Value>(id) {
            map.insert(id.get().to_string(), val);
        }
    }
    bytes_out(serde_json::to_vec(&Value::Object(map)).unwrap_or_default(), out_len)
}

/// Encodes an awareness update for all known clients (y-protocols v1).
#[no_mangle]
pub unsafe extern "C" fn ysync_encode_update(aw: *mut Awareness, out_len: *mut usize) -> *mut u8 {
    match (*aw).update() {
        Ok(update) => bytes_out(update.encode_v1(), out_len),
        Err(_) => {
            *out_len = 0;
            std::ptr::null_mut()
        }
    }
}

/// Encodes an awareness update restricted to the given client ids.
#[no_mangle]
pub unsafe extern "C" fn ysync_encode_update_clients(
    aw: *mut Awareness,
    clients: *const u64,
    clients_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let ids: Vec<ClientID> = if clients.is_null() || clients_len == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(clients, clients_len)
            .iter()
            .map(|&c| ClientID::new(c))
            .collect()
    };
    match (*aw).update_with_clients(ids) {
        Ok(update) => bytes_out(update.encode_v1(), out_len),
        Err(_) => {
            *out_len = 0;
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ysync_apply_update(aw: *mut Awareness, update: *const u8, len: usize) -> bool {
    match AwarenessUpdate::decode_v1(as_slice(update, len)) {
        Ok(update) => (*aw).apply_update(update).is_ok(),
        Err(_) => false,
    }
}

/// C callback: (user_data, added*, added_len, updated*, updated_len, removed*, removed_len).
pub type YAwarenessCallback =
    extern "C" fn(*mut c_void, *const u64, usize, *const u64, usize, *const u64, usize);

#[no_mangle]
pub unsafe extern "C" fn ysync_on_change(
    aw: *mut Awareness,
    cb: YAwarenessCallback,
    user_data: *mut c_void,
) -> *mut Subscription {
    let ud = user_data as usize;
    let sub = (*aw).on_change(move |_aw, e, _origin| {
        let added: Vec<u64> = e.added().iter().map(|c| c.get()).collect();
        let updated: Vec<u64> = e.updated().iter().map(|c| c.get()).collect();
        let removed: Vec<u64> = e.removed().iter().map(|c| c.get()).collect();
        cb(
            ud as *mut c_void,
            added.as_ptr(),
            added.len(),
            updated.as_ptr(),
            updated.len(),
            removed.as_ptr(),
            removed.len(),
        );
    });
    Box::into_raw(Box::new(sub))
}

// ---- Undo manager -----------------------------------------------------------
// undo/redo open their own transaction; callers must ensure no other transaction
// is active on the document (the Swift side serializes via the doc lock).

#[no_mangle]
pub unsafe extern "C" fn yundo_new(
    doc: *mut Doc,
    name: *const u8,
    name_len: usize,
    capture_timeout_ms: u64,
) -> *mut UndoManager<()> {
    let mut opts = UndoOptions::<()>::default();
    opts.capture_timeout_millis = capture_timeout_ms;
    let mut mgr: UndoManager<()> = UndoManager::with_options(opts);
    let text = (*doc).get_or_insert_text(as_str(name, name_len));
    mgr.expand_scope(&*doc, &text);
    Box::into_raw(Box::new(mgr))
}

#[no_mangle]
pub unsafe extern "C" fn yundo_include_origin(
    mgr: *mut UndoManager<()>,
    origin: *const u8,
    origin_len: usize,
) {
    (*mgr).include_origin(Origin::from(as_slice(origin, origin_len)));
}

#[no_mangle]
pub unsafe extern "C" fn yundo_undo(mgr: *mut UndoManager<()>) -> bool {
    (*mgr).undo_blocking()
}

#[no_mangle]
pub unsafe extern "C" fn yundo_redo(mgr: *mut UndoManager<()>) -> bool {
    (*mgr).redo_blocking()
}

#[no_mangle]
pub unsafe extern "C" fn yundo_can_undo(mgr: *mut UndoManager<()>) -> bool {
    (*mgr).can_undo()
}

#[no_mangle]
pub unsafe extern "C" fn yundo_can_redo(mgr: *mut UndoManager<()>) -> bool {
    (*mgr).can_redo()
}

#[no_mangle]
pub unsafe extern "C" fn yundo_stop_capturing(mgr: *mut UndoManager<()>) {
    (*mgr).reset();
}

#[no_mangle]
pub unsafe extern "C" fn yundo_free(mgr: *mut UndoManager<()>) {
    if !mgr.is_null() {
        drop(Box::from_raw(mgr));
    }
}

// ---- Memory -----------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn ybytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
    }
}

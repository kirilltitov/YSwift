//! Cross-checks `yrs` against the JS-Yjs golden vectors (yjs 13.6.31).
//!
//! This proves — before any FFI/Swift wiring — that `yrs`, configured for Yjs
//! compatibility (UTF-16 offsets, fixed client id, v1 encoding), reproduces the
//! exact bytes and text that JS-Yjs produces for the same operations.

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use cyrs::{ydoc_destroy, ydoc_new, ytxn, ytxn_apply_update_v1, ytxn_commit};
use serde_json::Value;
use std::sync::Arc;
use yrs::types::Attrs;
use yrs::updates::encoder::Encode;
use yrs::{
    Any, ClientID, Doc, GetString, OffsetKind, Options, ReadTxn, StateVector, Text, TextRef,
    Transact, TransactionMut,
};
const KEY: &str = "content";

fn to_attrs(v: &Value) -> Attrs {
    let mut attrs = Attrs::new();
    for (k, val) in v.as_object().expect("attributes must be an object") {
        let any = match val {
            Value::Bool(b) => Any::from(*b),
            Value::String(s) => Any::String(Arc::from(s.as_str())),
            Value::Number(n) if n.is_i64() => Any::BigInt(n.as_i64().unwrap()),
            Value::Number(n) => Any::Number(n.as_f64().unwrap()),
            Value::Null => Any::Null,
            other => panic!("unsupported attribute value: {other:?}"),
        };
        attrs.insert(Arc::from(k.as_str()), any);
    }
    attrs
}

fn apply_op(text: &TextRef, txn: &mut TransactionMut, o: &Value) {
    let idx = || o["index"].as_u64().unwrap() as u32;
    match o["op"].as_str().unwrap() {
        "insert" => {
            let s = o["text"].as_str().unwrap();
            match o.get("attributes") {
                Some(a) if !a.is_null() => text.insert_with_attributes(txn, idx(), s, to_attrs(a)),
                _ => text.insert(txn, idx(), s),
            }
        }
        "delete" => text.remove_range(txn, idx(), o["length"].as_u64().unwrap() as u32),
        "format" => text.format(
            txn,
            idx(),
            o["length"].as_u64().unwrap() as u32,
            to_attrs(&o["attributes"]),
        ),
        other => panic!("unknown op: {other}"),
    }
}

/// Builds a doc from structured ops and returns (v1 update, v1 state vector, text).
fn build(client_id: u64, ops: &[Value]) -> (Vec<u8>, Vec<u8>, String) {
    let doc = Doc::with_options(Options {
        client_id: ClientID::new(client_id),
        offset_kind: OffsetKind::Utf16,
        ..Default::default()
    });
    let text = doc.get_or_insert_text(KEY);
    {
        let mut txn = doc.transact_mut();
        for o in ops {
            apply_op(&text, &mut txn, o);
        }
    } // commit on drop, mirroring a Yjs transaction
    let txn = doc.transact();
    let update = txn.encode_state_as_update_v1(&StateVector::default());
    let sv = txn.state_vector().encode_v1();
    (update, sv, text.get_string(&txn))
}

fn load_suite() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../Tests/YSwiftTests/Fixtures/golden_v13_6_31.json"
    );
    let raw = std::fs::read_to_string(path).expect("read golden fixtures");
    serde_json::from_str(&raw).expect("parse golden fixtures")
}

#[test]
fn yrs_reproduces_yjs_encode_vectors() {
    let suite = load_suite();
    let mut failures = Vec::new();

    for f in suite["encode"].as_array().unwrap() {
        let name = f["name"].as_str().unwrap();
        let (update, sv, text) = build(
            f["clientID"].as_u64().unwrap(),
            f["ops"].as_array().unwrap(),
        );
        let exp_update = STANDARD.decode(f["update"].as_str().unwrap()).unwrap();
        let exp_sv = STANDARD.decode(f["stateVector"].as_str().unwrap()).unwrap();
        let exp_text = f["text"].as_str().unwrap();

        if text != exp_text {
            failures.push(format!("{name}: text {text:?} != {exp_text:?}"));
        }
        if sv != exp_sv {
            failures.push(format!("{name}: state-vector mismatch\n    got {sv:?}\n    exp {exp_sv:?}"));
        }
        if update != exp_update {
            failures.push(format!("{name}: update mismatch\n    got {update:?}\n    exp {exp_update:?}"));
        }
    }

    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}

#[test]
fn c_apply_requires_one_complete_v1_update() {
    unsafe {
        let doc = ydoc_new(42, false);
        let txn = ytxn(doc);

        let canonical_empty = [0_u8, 0_u8];
        assert!(ytxn_apply_update_v1(
            txn,
            canonical_empty.as_ptr(),
            canonical_empty.len()
        ));

        let trailing = [0_u8, 0_u8, 0xff_u8];
        assert!(!ytxn_apply_update_v1(
            txn,
            trailing.as_ptr(),
            trailing.len()
        ));

        let truncated = [0_u8];
        assert!(!ytxn_apply_update_v1(
            txn,
            truncated.as_ptr(),
            truncated.len()
        ));

        ytxn_commit(txn);
        ydoc_destroy(doc);
    }
}

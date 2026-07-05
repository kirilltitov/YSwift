// Generates golden wire-format vectors from the pinned JS-Yjs (v13.6.31).
//
// The output feeds YSwift's conformance suite: the port must produce byte-identical
// updates/state-vectors for the same operations, and reproduce the same text/delta
// when applying these updates. Regenerate with `npm ci && npm run generate`.
//
// Determinism: client ids are fixed (Yjs picks a random one by default) so encoded
// bytes are reproducible. `ops` are structured so the Swift side can replay them.

import * as Y from 'yjs'
import { writeFileSync, mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const YJS_VERSION = '13.6.31'
const KEY = 'content' // single text type per block (requirements §3)

const b64 = (u8) => Buffer.from(u8).toString('base64')

/** Replays structured ops in one transaction. Mirrors the Swift conformance runner. */
function applyOps(doc, ops) {
  const t = doc.getText(KEY)
  doc.transact(() => {
    for (const o of ops) {
      switch (o.op) {
        case 'insert': t.insert(o.index, o.text, o.attributes ?? undefined); break
        case 'delete': t.delete(o.index, o.length); break
        case 'format': t.format(o.index, o.length, o.attributes); break
        default: throw new Error(`unknown op: ${o.op}`)
      }
    }
  })
  return t
}

function docWith(clientID, ops) {
  const doc = new Y.Doc()
  doc.clientID = clientID
  const t = applyOps(doc, ops)
  return { doc, t }
}

function encodeFixture(name, description, clientID, ops) {
  const { doc, t } = docWith(clientID, ops)
  return {
    name, description, clientID, ops,
    text: t.toString(),
    deltaJSON: JSON.stringify(t.toDelta()),
    stateVector: b64(Y.encodeStateVector(doc)),
    update: b64(Y.encodeStateAsUpdate(doc)),
  }
}

function mergeFixture(name, description, specs) {
  const inputs = specs.map((s) => Y.encodeStateAsUpdate(docWith(s.clientID, s.ops).doc))
  const merged = Y.mergeUpdates(inputs)
  const result = new Y.Doc()
  Y.applyUpdate(result, merged)
  return {
    name, description,
    inputs: inputs.map(b64),
    merged: b64(merged),
    text: result.getText(KEY).toString(),
  }
}

function convergeFixture(name, description, specs) {
  const updates = specs.map((s) => Y.encodeStateAsUpdate(docWith(s.clientID, s.ops).doc))
  const forward = new Y.Doc(); updates.forEach((u) => Y.applyUpdate(forward, u))
  const reverse = new Y.Doc(); [...updates].reverse().forEach((u) => Y.applyUpdate(reverse, u))
  const t1 = forward.getText(KEY).toString()
  const t2 = reverse.getText(KEY).toString()
  if (t1 !== t2) throw new Error(`non-convergent fixture: ${name} (${JSON.stringify(t1)} != ${JSON.stringify(t2)})`)
  return { name, description, updates: updates.map(b64), text: t1 }
}

function diffFixture(name, description, clientID, opsA, opsB) {
  const doc = new Y.Doc(); doc.clientID = clientID
  applyOps(doc, opsA)
  const sinceSV = Y.encodeStateVector(doc)
  const base = Y.encodeStateAsUpdate(doc)
  applyOps(doc, opsB)
  return {
    name, description, clientID,
    sinceStateVector: b64(sinceSV),
    base: b64(base),
    full: b64(Y.encodeStateAsUpdate(doc)),
    diff: b64(Y.encodeStateAsUpdate(doc, sinceSV)),
    text: doc.getText(KEY).toString(),
  }
}

/** Applies one op to `t` (no transaction wrapper). */
function applyOp1(t, o) {
  switch (o.op) {
    case 'insert': t.insert(o.index, o.text, o.attributes ?? undefined); break
    case 'delete': t.delete(o.index, o.length); break
    case 'format': t.format(o.index, o.length, o.attributes); break
    default: throw new Error(`unknown op: ${o.op}`)
  }
}

/** Captures the v1 incremental update fired per transaction (Yjs `update` event). */
function incrementalFixture(name, description, clientID, transactions) {
  const doc = new Y.Doc()
  doc.clientID = clientID
  const updates = []
  doc.on('update', (u) => updates.push(b64(u)))
  const t = doc.getText(KEY)
  for (const ops of transactions) {
    doc.transact(() => { for (const o of ops) applyOp1(t, o) })
  }
  return { name, description, clientID, transactions, updates, text: t.toString() }
}

/** Sticky (relative) position: encode it, resolve before/after a shifting edit. */
function stickyFixture(name, description, clientID, baseOps, index, assoc, shiftOps) {
  const doc = new Y.Doc()
  doc.clientID = clientID
  const t = applyOps(doc, baseOps)
  const rel = Y.createRelativePositionFromTypeIndex(t, index, assoc)
  const encoded = b64(Y.encodeRelativePosition(rel))
  const before = Y.createAbsolutePositionFromRelativePosition(rel, doc)
  applyOps(doc, shiftOps)
  const after = Y.createAbsolutePositionFromRelativePosition(rel, doc)
  return {
    name, description, clientID, baseOps, index, assoc, shiftOps,
    encoded,
    resolvedBefore: before ? before.index : -1,
    resolvedAfter: after ? after.index : -1,
    finalText: t.toString(),
  }
}

const encode = [
  encodeFixture('empty', 'new doc, no ops', 1001, []),
  encodeFixture('ascii', 'plain ascii insert', 1001,
    [{ op: 'insert', index: 0, text: 'Hello, world!' }]),
  encodeFixture('unicode_surrogates', 'astral chars: emoji + flag (UTF-16 surrogate pairs)', 1001,
    [{ op: 'insert', index: 0, text: 'a😀b🇺🇸c' }]),
  encodeFixture('bold_range', 'insert then bold a range', 1001,
    [{ op: 'insert', index: 0, text: 'Hello' }, { op: 'format', index: 0, length: 5, attributes: { bold: true } }]),
  encodeFixture('attributed_insert', 'attributed then plain insert', 1001,
    [{ op: 'insert', index: 0, text: 'x', attributes: { bold: true } }, { op: 'insert', index: 1, text: 'y' }]),
  encodeFixture('delete_middle', 'insert then delete a middle range', 1001,
    [{ op: 'insert', index: 0, text: 'abcdef' }, { op: 'delete', index: 2, length: 2 }]),
  encodeFixture('mixed', 'insert, italic range, delete head', 1001,
    [{ op: 'insert', index: 0, text: 'The quick brown fox' }, { op: 'format', index: 4, length: 5, attributes: { italic: true } }, { op: 'delete', index: 0, length: 4 }]),
  encodeFixture('link', 'insert with a link attribute (string value)', 1001,
    [{ op: 'insert', index: 0, text: 'site', attributes: { link: 'https://example.com' } }]),
]

const merge = [
  mergeFixture('merge_two_clients', 'two clients, disjoint inserts, merged into one update', [
    { clientID: 1, ops: [{ op: 'insert', index: 0, text: 'Hello ' }] },
    { clientID: 2, ops: [{ op: 'insert', index: 0, text: 'World' }] },
  ]),
]

const converge = [
  convergeFixture('interleave_same_pos', 'two clients insert at position 0 concurrently (YATA tie-break)', [
    { clientID: 1, ops: [{ op: 'insert', index: 0, text: 'AAA' }] },
    { clientID: 2, ops: [{ op: 'insert', index: 0, text: 'BBB' }] },
  ]),
]

const diff = [
  diffFixture('diff_append', 'diff (delta) after appending to an earlier state', 1001,
    [{ op: 'insert', index: 0, text: 'Hello' }],
    [{ op: 'insert', index: 5, text: ', world' }]),
]

const incremental = [
  incrementalFixture('typing', 'three single-char inserts, one transaction each', 1001, [
    [{ op: 'insert', index: 0, text: 'a' }],
    [{ op: 'insert', index: 1, text: 'b' }],
    [{ op: 'insert', index: 2, text: 'c' }],
  ]),
  incrementalFixture('insert_then_delete', 'insert, then delete a range in a later transaction', 1001, [
    [{ op: 'insert', index: 0, text: 'hello world' }],
    [{ op: 'delete', index: 5, length: 6 }],
  ]),
  incrementalFixture('format_pass', 'insert then bold, two transactions', 1001, [
    [{ op: 'insert', index: 0, text: 'title' }],
    [{ op: 'format', index: 0, length: 5, attributes: { bold: true } }],
  ]),
]

const sticky = [
  stickyFixture('mid_after', 'sticky at index 3 (assoc after) in "hello", then insert "XY" at 0', 1001,
    [{ op: 'insert', index: 0, text: 'hello' }], 3, 0, [{ op: 'insert', index: 0, text: 'XY' }]),
  stickyFixture('start_before', 'sticky at index 2 (assoc before) in "world", then insert "!" at 0', 2002,
    [{ op: 'insert', index: 0, text: 'world' }], 2, -1, [{ op: 'insert', index: 0, text: '!' }]),
]

const out = {
  meta: { yjsVersion: YJS_VERSION, format: 'v1', key: KEY, generatedBy: 'fixtures/generate.mjs' },
  encode, merge, converge, diff, incremental, sticky,
}

const here = dirname(fileURLToPath(import.meta.url))
const dest = join(here, '..', 'Tests', 'YSwiftTests', 'Fixtures')
mkdirSync(dest, { recursive: true })
writeFileSync(join(dest, 'golden_v13_6_31.json'), JSON.stringify(out, null, 2) + '\n')

const count = encode.length + merge.length + converge.length + diff.length + incremental.length + sticky.length
console.log(`wrote ${count} fixtures (yjs ${YJS_VERSION}) -> Tests/YSwiftTests/Fixtures/golden_v13_6_31.json`)

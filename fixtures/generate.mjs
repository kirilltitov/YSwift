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

/** Semantically-equivalent-but-not-byte-exact scenarios (e.g. multi-attribute format). */
function semanticFixture(name, description, clientID, ops) {
  const { doc, t } = docWith(clientID, ops)
  return {
    name, description, clientID, ops,
    update: b64(Y.encodeStateAsUpdate(doc)),
    text: t.toString(),
    deltaJSON: JSON.stringify(t.toDelta()),
  }
}

// --- Containers (Y.Array / Y.Map) — extension beyond the §4 text subset. ---

function arrayFixture(name, description, clientID, ops) {
  const doc = new Y.Doc()
  doc.clientID = clientID
  const a = doc.getArray(KEY)
  doc.transact(() => {
    for (const o of ops) {
      switch (o.op) {
        case 'insert': a.insert(o.index, o.values); break
        case 'delete': a.delete(o.index, o.length); break
        default: throw new Error(`unknown array op: ${o.op}`)
      }
    }
  })
  return {
    name, description, clientID, ops,
    json: JSON.stringify(a.toJSON()),
    stateVector: b64(Y.encodeStateVector(doc)),
    update: b64(Y.encodeStateAsUpdate(doc)),
  }
}

function mapFixture(name, description, clientID, ops) {
  const doc = new Y.Doc()
  doc.clientID = clientID
  const m = doc.getMap(KEY)
  doc.transact(() => {
    for (const o of ops) {
      switch (o.op) {
        case 'set': m.set(o.key, o.value); break
        case 'delete': m.delete(o.key); break
        default: throw new Error(`unknown map op: ${o.op}`)
      }
    }
  })
  return {
    name, description, clientID, ops,
    json: JSON.stringify(m.toJSON()),
    stateVector: b64(Y.encodeStateVector(doc)),
    update: b64(Y.encodeStateAsUpdate(doc)),
  }
}

// Builds a detached Y.Xml node from a spec: { text } | { tag, attrs?: [[k,v]], children?: [node] }.
// Children are appended, then attributes set — yjs integrates prelim children
// before prelim attributes, so this fixes the clock order the Swift builder mirrors.
function buildXmlNode(spec) {
  if (spec.text !== undefined) return new Y.XmlText(spec.text)
  const el = new Y.XmlElement(spec.tag)
  for (const child of spec.children ?? []) el.insert(el.length, [buildXmlNode(child)])
  for (const [k, v] of spec.attrs ?? []) el.setAttribute(k, v)
  return el
}

function xmlFixture(name, description, clientID, nodes) {
  const doc = new Y.Doc()
  doc.clientID = clientID
  const f = doc.getXmlFragment(KEY)
  doc.transact(() => {
    f.insert(0, nodes.map(buildXmlNode))
  })
  return {
    name, description, clientID, nodes,
    xml: f.toString(),
    stateVector: b64(Y.encodeStateVector(doc)),
    update: b64(Y.encodeStateAsUpdate(doc)),
  }
}

const xml = [
  xmlFixture('xml_simple', 'one element with an attribute and a text child', 1001,
    [{ tag: 'p', attrs: [['class', 'intro']], children: [{ text: 'Hello' }] }]),
  xmlFixture('xml_text_child', 'element with only text', 1001,
    [{ tag: 'span', children: [{ text: 'hi' }] }]),
  xmlFixture('xml_nested', 'div with two paragraph children', 1001,
    [{ tag: 'div', children: [
      { tag: 'p', children: [{ text: 'a' }] },
      { tag: 'p', children: [{ text: 'b' }] },
    ] }]),
  xmlFixture('xml_siblings', 'fragment with an element then a bare text node', 1001,
    [{ tag: 'b', children: [{ text: 'x' }] }, { text: 'tail' }]),
]

const array = [
  arrayFixture('array_numbers', 'insert three numbers', 1001,
    [{ op: 'insert', index: 0, values: [1, 2, 3] }]),
  arrayFixture('array_mixed', 'mixed scalar values', 1001,
    [{ op: 'insert', index: 0, values: ['a', true, null, 42] }]),
  arrayFixture('array_nested', 'nested json array + object values', 1001,
    [{ op: 'insert', index: 0, values: [[1, 2], { k: 'v' }] }]),
  arrayFixture('array_delete', 'insert five, delete a middle run', 1001,
    [{ op: 'insert', index: 0, values: [1, 2, 3, 4, 5] }, { op: 'delete', index: 1, length: 2 }]),
  arrayFixture('array_multi_insert', 'two inserts, second splits the first run', 1001,
    [{ op: 'insert', index: 0, values: [1, 2] }, { op: 'insert', index: 1, values: [9] }]),
]

const map = [
  mapFixture('map_basic', 'set a number and a string', 1001,
    [{ op: 'set', key: 'a', value: 1 }, { op: 'set', key: 'b', value: 'hi' }]),
  mapFixture('map_types', 'null / array / object / bool values', 1001,
    [{ op: 'set', key: 'n', value: null }, { op: 'set', key: 'arr', value: [1, 2] },
     { op: 'set', key: 'obj', value: { x: 1 } }, { op: 'set', key: 'flag', value: true }]),
  mapFixture('map_overwrite', 'overwriting a key keeps the last value', 1001,
    [{ op: 'set', key: 'k', value: 1 }, { op: 'set', key: 'k', value: 2 }]),
  mapFixture('map_delete', 'set two keys, delete one', 1001,
    [{ op: 'set', key: 'a', value: 1 }, { op: 'set', key: 'b', value: 2 }, { op: 'delete', key: 'a' }]),
]

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

const semantic = [
  semanticFixture(
    'multi_attr_format',
    'multi-attribute format: yrs writes the independent per-attribute structs in HashMap order, differing from yjs insertion order — semantically identical (converges) but not byte-identical',
    1001,
    [{ op: 'insert', index: 0, text: 'text' }, { op: 'format', index: 0, length: 4, attributes: { bold: true, italic: true } }]
  ),
]

const out = {
  meta: { yjsVersion: YJS_VERSION, format: 'v1', key: KEY, generatedBy: 'fixtures/generate.mjs' },
  encode, merge, converge, diff, incremental, sticky, semantic, array, map, xml,
}

const here = dirname(fileURLToPath(import.meta.url))
const dest = join(here, '..', 'Tests', 'YSwiftTests', 'Fixtures')
mkdirSync(dest, { recursive: true })
writeFileSync(join(dest, 'golden_v13_6_31.json'), JSON.stringify(out, null, 2) + '\n')

const count =
  encode.length + merge.length + converge.length + diff.length + incremental.length + sticky.length
  + semantic.length + array.length + map.length + xml.length
console.log(`wrote ${count} fixtures (yjs ${YJS_VERSION}) -> Tests/YSwiftTests/Fixtures/golden_v13_6_31.json`)

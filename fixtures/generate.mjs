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

/** Map ops in one transaction, or with `oneTransactionEach` one transaction per op, recording the
 *  update each transaction emits. */
function mapFixture(name, description, clientID, ops, oneTransactionEach = false) {
  const doc = new Y.Doc()
  doc.clientID = clientID
  const updates = []
  doc.on('update', (u) => updates.push(b64(u)))
  const m = doc.getMap(KEY)
  const apply = (o) => {
    switch (o.op) {
      case 'set': m.set(o.key, o.value); break
      case 'delete': m.delete(o.key); break
      default: throw new Error(`unknown map op: ${o.op}`)
    }
  }
  if (oneTransactionEach) {
    for (const o of ops) doc.transact(() => apply(o))
  } else {
    doc.transact(() => { for (const o of ops) apply(o) })
  }
  return {
    name, description, clientID, ops,
    ...(oneTransactionEach ? { updates } : {}),
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
  // Attributes listed in sorted-key order: the native builder sorts attribute keys,
  // so this stays byte-exact. (Interop with a peer that set attributes in a
  // different order is a semantic match only — the public API takes an unordered
  // attribute dictionary, exactly like multi-attribute text formatting.)
  xmlFixture('xml_multi_attr', 'element with two attributes (sorted keys)', 1001,
    [{ tag: 'a', attrs: [['href', 'https://x.y'], ['title', 'link']], children: [{ text: 'go' }] }]),
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
  // A merge that absorbs a key's current value makes the merged item the current value
  // (tryToMergeWithLefts), so the next set links to it and merges again.
  mapFixture('map_merged_value_stays_current', 'set/delete one key, one transaction per op', 1001,
    [{ op: 'set', key: 'k', value: 1 }, { op: 'set', key: 'k', value: 2 }, { op: 'delete', key: 'k' },
     { op: 'set', key: 'k', value: 3 }, { op: 'delete', key: 'k' }, { op: 'set', key: 'k', value: 4 }], true),
  // Only a merge that absorbs the current value moves the key: overwritten values merge among
  // themselves behind it.
  mapFixture('map_overwritten_values_merge_behind_current', 'set one key four times, one transaction per op', 1001,
    [{ op: 'set', key: 'k', value: 1 }, { op: 'set', key: 'k', value: 2 }, { op: 'set', key: 'k', value: 3 },
     { op: 'set', key: 'k', value: 4 }], true),
]

// --- Container convergence: concurrent multi-client edits must converge. ---

function applyContainerOps(doc, kind, ops) {
  if (kind === 'array') {
    const a = doc.getArray(KEY)
    for (const o of ops) {
      if (o.op === 'insert') a.insert(o.index, o.values)
      else if (o.op === 'delete') a.delete(o.index, o.length)
    }
  } else if (kind === 'map') {
    const m = doc.getMap(KEY)
    for (const o of ops) {
      if (o.op === 'set') m.set(o.key, o.value)
      else if (o.op === 'delete') m.delete(o.key)
    }
  }
}

function containerJSON(doc, kind) {
  return JSON.stringify((kind === 'array' ? doc.getArray(KEY) : doc.getMap(KEY)).toJSON())
}

// Concurrent from empty (each client builds independently); tests YATA tie-break /
// last-writer. `base` (optional) is a shared prefix applied by all clients.
function convergeContainerFixture(name, description, kind, specs, baseOps = null) {
  const updates = []
  let baseUpdate = null
  let baseSV = null
  if (baseOps) {
    const baseDoc = new Y.Doc()
    baseDoc.clientID = 100
    applyContainerOps(baseDoc, kind, baseOps)
    baseUpdate = Y.encodeStateAsUpdate(baseDoc)
    baseSV = Y.encodeStateVector(baseDoc)
    updates.push(b64(baseUpdate))
  }
  for (const s of specs) {
    const doc = new Y.Doc()
    doc.clientID = s.clientID
    if (baseUpdate) Y.applyUpdate(doc, baseUpdate)
    applyContainerOps(doc, kind, s.ops)
    updates.push(b64(baseSV ? Y.encodeStateAsUpdate(doc, baseSV) : Y.encodeStateAsUpdate(doc)))
  }
  // Converge by applying every update (forward) to a fresh doc.
  const merged = new Y.Doc()
  for (const u of updates) Y.applyUpdate(merged, Uint8Array.from(Buffer.from(u, 'base64')))
  return { name, description, kind, updates, json: containerJSON(merged, kind) }
}

const containerConverge = [
  convergeContainerFixture('array_concurrent_head', 'two clients insert at index 0 concurrently', 'array', [
    { clientID: 1, ops: [{ op: 'insert', index: 0, values: [1, 2] }] },
    { clientID: 2, ops: [{ op: 'insert', index: 0, values: [3, 4] }] },
  ]),
  convergeContainerFixture('array_base_insert_delete', 'shared base, one inserts while the other deletes', 'array', [
    { clientID: 1, ops: [{ op: 'insert', index: 1, values: [9] }] },
    { clientID: 2, ops: [{ op: 'delete', index: 0, length: 1 }] },
  ], [{ op: 'insert', index: 0, values: [1, 2, 3] }]),
  convergeContainerFixture('map_concurrent_same_key', 'two clients set the same key (LWW tie-break)', 'map', [
    { clientID: 1, ops: [{ op: 'set', key: 'k', value: 'A' }] },
    { clientID: 2, ops: [{ op: 'set', key: 'k', value: 'B' }] },
  ]),
  convergeContainerFixture('map_concurrent_diff_keys', 'two clients set different keys', 'map', [
    { clientID: 1, ops: [{ op: 'set', key: 'a', value: 1 }] },
    { clientID: 2, ops: [{ op: 'set', key: 'b', value: 2 }] },
  ]),
  convergeContainerFixture('map_base_set_vs_delete', 'shared base key; one overwrites while the other deletes', 'map', [
    { clientID: 1, ops: [{ op: 'set', key: 'k', value: 1 }] },
    { clientID: 2, ops: [{ op: 'delete', key: 'k' }] },
  ], [{ op: 'set', key: 'k', value: 0 }]),
]

// --- Randomised differential convergence fuzz (recorded; §10.3 property test). ---
// Seeded so fixtures are reproducible: random concurrent ops on a shared base,
// per client, then the state yjs converges to. The port must reach the same state
// applying the updates in any order.

function makeRng(seed) {
  let s = seed >>> 0
  return () => {
    s = (s + 0x6d2b79f5) >>> 0
    let t = Math.imul(s ^ (s >>> 15), 1 | s)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function fuzzRandStr(rng) {
  const n = 1 + Math.floor(rng() * 4)
  let out = ''
  for (let i = 0; i < n; i++) out += String.fromCharCode(97 + Math.floor(rng() * 26))
  return out
}

function fuzzRandVal(rng) {
  const r = rng()
  if (r < 0.4) return Math.floor(rng() * 100)
  if (r < 0.7) return fuzzRandStr(rng)
  if (r < 0.85) return rng() < 0.5
  return null
}

function fuzzApply(doc, kind, rng, count) {
  doc.transact(() => {
    if (kind === 'text') {
      const t = doc.getText(KEY)
      for (let i = 0; i < count; i++) {
        const len = t.length
        if (len === 0 || rng() < 0.7) t.insert(Math.floor(rng() * (len + 1)), fuzzRandStr(rng))
        else {
          const idx = Math.floor(rng() * len)
          t.delete(idx, Math.min(1 + Math.floor(rng() * 2), len - idx))
        }
      }
    } else if (kind === 'array') {
      const a = doc.getArray(KEY)
      for (let i = 0; i < count; i++) {
        const len = a.length
        if (len === 0 || rng() < 0.7) {
          const vals = []
          for (let j = 0, m = 1 + Math.floor(rng() * 2); j < m; j++) vals.push(fuzzRandVal(rng))
          a.insert(Math.floor(rng() * (len + 1)), vals)
        } else {
          const idx = Math.floor(rng() * len)
          a.delete(idx, Math.min(1 + Math.floor(rng() * 2), len - idx))
        }
      }
    } else {
      const m = doc.getMap(KEY)
      const keys = ['a', 'b', 'c', 'd']
      for (let i = 0; i < count; i++) {
        const k = keys[Math.floor(rng() * keys.length)]
        if (rng() < 0.7) m.set(k, fuzzRandVal(rng))
        else m.delete(k)
      }
    }
  })
}

function fuzzScenario(kind, seed) {
  const rng = makeRng(seed)
  const base = new Y.Doc()
  base.clientID = 100
  fuzzApply(base, kind, rng, 2 + Math.floor(rng() * 3))
  const baseUpdate = Y.encodeStateAsUpdate(base)
  const baseSV = Y.encodeStateVector(base)
  const updates = [b64(baseUpdate)]
  const numClients = 2 + Math.floor(rng() * 2)
  for (let c = 0; c < numClients; c++) {
    const doc = new Y.Doc()
    doc.clientID = 1 + c
    Y.applyUpdate(doc, baseUpdate)
    fuzzApply(doc, kind, rng, 1 + Math.floor(rng() * 4))
    updates.push(b64(Y.encodeStateAsUpdate(doc, baseSV)))
  }
  const merged = new Y.Doc()
  for (const u of updates) Y.applyUpdate(merged, Uint8Array.from(Buffer.from(u, 'base64')))
  const state =
    kind === 'text'
      ? merged.getText(KEY).toString()
      : JSON.stringify((kind === 'array' ? merged.getArray(KEY) : merged.getMap(KEY)).toJSON())
  return { name: `${kind}_fuzz_${seed}`, kind, updates, state }
}

const fuzz = []
for (const kind of ['text', 'array', 'map']) {
  for (let seed = 1; seed <= 12; seed++) fuzz.push(fuzzScenario(kind, seed * 2654435761))
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

const semantic = [
  semanticFixture(
    'multi_attr_format',
    'multi-attribute format: Swift dictionaries do not preserve caller insertion order, so YSwift emits deterministic sorted-key order — semantically identical (converges) but not always byte-identical to yjs',
    1001,
    [{ op: 'insert', index: 0, text: 'text' }, { op: 'format', index: 0, length: 4, attributes: { bold: true, italic: true } }]
  ),
]

// --- Malformed references: hand-built v1 updates, applied to one document one per transaction. ---
// Yjs resolves an item's references to its own client without checking them against the state, so
// a reference to a clock that client has not reached makes the lookup throw. `rejected` is the
// index of the update Yjs throws on (null when it accepts all); `update` is the state it ends with.

const varUint = (n) => { const out = []; while (n > 127) { out.push(0x80 | (n & 127)); n = Math.floor(n / 128) } out.push(n); return out }
const varString = (s) => { const bytes = [...Buffer.from(s, 'utf8')]; return [...varUint(bytes.length), ...bytes] }
/** One client's structs from `clock` on, and an empty delete set. */
const rawUpdate = (client, clock, structs) =>
  b64(new Uint8Array([1, ...varUint(structs.length), ...varUint(client), ...varUint(clock), ...structs.flat(), 0]))
const rootString = (text) => [0x04, 1, ...varString(KEY), ...varString(text)]
const rootMapType = () => [0x07, 1, ...varString(KEY), 1]
const rootAnyFalse = (count) => [0x08, 1, ...varString(KEY), ...varUint(count), ...new Array(count).fill(121)]
/** Root any content holding one number too large for an integer. */
const rootAnyNumber = (value) => {
  const float64 = Buffer.alloc(8)
  float64.writeDoubleBE(value)
  return [0x08, 1, ...varString(KEY), 1, 123, ...float64]
}
const stringAfter = (client, clock, text) => [0x84, ...varUint(client), ...varUint(clock), ...varString(text)]
const stringBefore = (client, clock, text) => [0x44, ...varUint(client), ...varUint(clock), ...varString(text)]
const embedAfter = (client, clock, json) => [0x85, ...varUint(client), ...varUint(clock), ...varString(json)]
const mapEntryIn = (client, clock, key) => [0x28, 0, ...varUint(client), ...varUint(clock), ...varString(key), 1, 125, 1]
/** Deleted content of `length` clocks, an entry `key` of the type at `parent` (a client and a clock). */
const deletedEntryIn = (client, clock, key, length) =>
  [0x21, 0, ...varUint(client), ...varUint(clock), ...varString(key), ...varUint(length)]
/** An update without structs, deleting `ranges` ([clock, length] pairs) of one client. */
const deleteRanges = (client, ranges) => b64(new Uint8Array([
  0, 1, ...varUint(client), ...varUint(ranges.length), ...ranges.flatMap(([clock, length]) => [...varUint(clock), ...varUint(length)]),
]))
/** Lists nested `depth` deep, level j by client 1000 + j, and an update deleting them innermost first:
 *  undoing it re-creates the innermost first, which re-creates every level above it first. */
const nestedAcrossClients = (depth) => {
  const levels = range(depth, (i) => depth - 1 - i)
  return [
    b64(new Uint8Array([...varUint(depth), ...levels.flatMap((j) => [
      1, ...varUint(1000 + j), 0, 0x07, ...(j === 0 ? [1, ...varString(KEY)] : [0, ...varUint(999 + j), 0]), 0,
    ]), 0])),
    b64(new Uint8Array([0, ...varUint(depth), ...levels.flatMap((j) => [...varUint(1000 + j), 1, 0, 1])])),
  ]
}
/** `depth` nested lists (client 5) with a string of 2 × `count` units (client 6) in the innermost, and
 *  an update deleting every other unit of it. */
const deepScope = (depth, count) => [
  b64(new Uint8Array([
    2, 1, 6, 0, 0x04, 0, 5, ...varUint(depth - 1), ...varString('x'.repeat(2 * count)),
    ...varUint(depth), 5, 0, ...range(depth, (k) => [0x07, ...(k === 0 ? [1, ...varString(KEY)] : [0, 5, ...varUint(k - 1)]), 0]).flat(),
    0,
  ])),
  deleteRanges(6, range(count, (i) => [2 * i, 1])),
]
/** `depth` XML elements `p` of client 5, each a child of the one before. */
const nestedElements = (depth) => rawUpdate(5, 0, range(depth, (k) => [
  0x07, ...(k === 0 ? [1, ...varString(KEY)] : [0, 5, ...varUint(k - 1)]), 3, ...varString('p'),
]))
/** An update setting root map key `a` to a number, which replaces the key's current value. */
const rootEntry = (client) => rawUpdate(client, 0, [[0x28, 1, ...varString(KEY), ...varString('a'), 1, 125, 1]])
const range = (count, at) => Array.from({ length: count }, (_, index) => at(index))
/** `depth` types of one client, each nested in the one before as map entry `a` (`map`) or list element. */
const nestedChain = (client, depth, map) => rawUpdate(client, 0, Array.from({ length: depth }, (_, k) => [
  0x07 | (map ? 0x20 : 0),
  ...(k === 0 ? [1, ...varString(KEY)] : [0, ...varUint(client), ...varUint(k - 1)]),
  ...(map ? varString('a') : []),
  map ? 1 : 0,
]))

/** With `tracked`, an UndoManager on the root tracks the updates from that index on (origin `r`) and,
 *  once all are applied, undoes and redoes the last of them. With `xml`, the root's XML string is
 *  recorded too. `gc: false` replays into a document that keeps deleted content. */
function malformedFixture(name, description, updates, { tracked = null, xml = false, gc = true } = {}) {
  const doc = new Y.Doc({ gc })
  doc.clientID = 999
  const um = tracked === null
    ? null
    : new Y.UndoManager(doc.getText(KEY), { trackedOrigins: new Set(['r']), captureTimeout: 0 })
  let rejected = null
  for (const [index, update] of updates.entries()) {
    try {
      Y.applyUpdate(doc, Buffer.from(update, 'base64'), um !== null && index >= tracked ? 'r' : null)
    } catch {
      rejected = index
      break
    }
  }
  if (um !== null && rejected === null) {
    um.undo()
    um.redo()
  }
  return {
    name, description, updates, ...(tracked === null ? {} : { tracked }), ...(gc ? {} : { gc }),
    rejected, update: rejected === null ? b64(Y.encodeStateAsUpdate(doc)) : null,
    ...(xml && rejected === null ? { xml: doc.getXmlFragment(KEY).toString() } : {}),
  }
}

const malformed = [
  malformedFixture('origin_own_client_future', 'left origin at a clock of its own client not reached yet', [
    rawUpdate(5, 0, [rootString('a'), stringAfter(5, 10, 'b')])]),
  malformedFixture('origin_own_client_future_in_later_update', 'the same, the item arriving in a later update', [
    rawUpdate(5, 0, [rootString('a')]), rawUpdate(5, 1, [stringAfter(5, 10, 'b')])]),
  malformedFixture('origin_own_client_future_past_a_run', 'left origin past a run the document holds', [
    rawUpdate(5, 0, [rootString('a'), embedAfter(5, 0, '{"b":1}'), stringAfter(5, 1, 'bcdefghij')]),
    rawUpdate(5, 11, [stringAfter(5, 13, 'x')])]),
  // The bad item waits behind its client's item with a missing dependency, as the rest of that
  // client's structs do; a later update for the same clocks does not expose it, the dependency does.
  malformedFixture('origin_own_client_future_behind_a_missing_dependency', 'the same, set aside with a waiting item', [
    rawUpdate(5, 0, [rootString('a')]), rawUpdate(5, 1, [stringAfter(6, 0, 'b'), stringAfter(5, 10, 'c')]),
    rawUpdate(5, 1, [stringAfter(5, 0, 'b'), stringAfter(5, 1, 'c')]), rawUpdate(6, 0, [rootString('x')])]),
  malformedFixture('origin_own_client_unknown', 'left origin at a client the document has never seen', [
    rawUpdate(5, 0, [stringAfter(5, 3, 'a')])]),
  malformedFixture('origin_self', 'left origin at the item itself', [rawUpdate(5, 0, [stringAfter(5, 0, 'a')])]),
  malformedFixture('right_origin_own_client_future', 'right origin at a clock of its own client not reached yet', [
    rawUpdate(5, 0, [rootString('a'), stringBefore(5, 10, 'b')])]),
  malformedFixture('parent_own_client_future', 'parent at a clock of its own client not reached yet', [
    rawUpdate(5, 0, [rootMapType(), mapEntryIn(5, 10, 'k')])]),
  malformedFixture('parent_self', 'parent at the item itself', [rawUpdate(5, 0, [mapEntryIn(5, 0, 'k')])]),
  // Accepted: the references resolve.
  malformedFixture('origin_other_client', 'left origin at another client, present', [
    rawUpdate(5, 0, [rootString('a')]), rawUpdate(6, 0, [stringAfter(5, 0, 'b')])]),
  malformedFixture('origin_inside_resent_run', 'a run sent again with its left origin in the part already held', [
    rawUpdate(5, 0, [rootString('abcdef')]), rawUpdate(5, 0, [stringAfter(5, 3, 'abcdefghij')])]),
  malformedFixture('parent_not_a_type', 'parent at a string item: the item is collected', [
    rawUpdate(5, 0, [rootString('ab'), mapEntryIn(5, 0, 'k')])]),
  // A run sent again is linked in after the struct just before its first new clock, whatever that
  // struct's parent. Here it is the map's own item, which the new entry then replaces and deletes:
  // collecting the map walks from the entry back into the map without end, and yjs overflows its
  // stack. Without gc nothing is collected and yjs accepts it.
  malformedFixture('entry_resent_after_its_map_collected', 'a resent entry of a map linked after the map itself', [
    rawUpdate(5, 0, [rootMapType()]), rawUpdate(5, 0, [deletedEntryIn(5, 0, 'l', 2)])]),
  malformedFixture('entry_resent_after_its_map_kept', 'the same without gc', [
    rawUpdate(5, 0, [rootMapType()]), rawUpdate(5, 0, [deletedEntryIn(5, 0, 'l', 2)])], { gc: false }),
  // Size and depth: yjs accepts these; the document must survive them, and being dropped.
  // Yjs renders nested elements recursively and throws from 1172 levels on; YSwift renders any depth.
  malformedFixture('nested_elements', '1000 XML elements, each a child of the one before', [nestedElements(1000)],
    { xml: true }),
  malformedFixture('huge_number_in_text', 'an any value 1e300 in the text, which observers render',
    [rawUpdate(5, 0, [rootAnyNumber(1e300)])]),
  malformedFixture('infinity_in_text', 'an any value -Infinity in the text, which observers render',
    [rawUpdate(5, 0, [rootAnyNumber(-Infinity)])]),
  malformedFixture('nested_map_chain', '2000 maps, each an entry of the one before', [nestedChain(5, 2000, true)]),
  // Yjs deletes (and collects) a nested type recursively. On Node's default stack it deletes 3750 nested
  // lists and 2187 nested maps, and throws a RangeError from a few more; YSwift rejects past 4096.
  malformedFixture('nested_list_chain_deleted', '3000 nested lists, the outermost deleted', [
    nestedChain(5, 3000, false), deleteRanges(5, [[0, 1]])]),
  malformedFixture('nested_map_chain_deleted', '1000 nested maps, the outermost deleted', [
    nestedChain(5, 1000, true), deleteRanges(5, [[0, 1]])]),
  malformedFixture('nested_list_chain_deleted_too_deep', '5000 nested lists, the outermost deleted', [
    nestedChain(5, 5000, false), deleteRanges(5, [[0, 1]])]),
  malformedFixture('nested_map_chain_deleted_too_deep', '5000 nested maps, the outermost deleted', [
    nestedChain(5, 5000, true), deleteRanges(5, [[0, 1]])]),
  malformedFixture('nested_lists_redone_innermost_first', '2000 nested lists deleted innermost first, undone, redone',
    nestedAcrossClients(2000), { tracked: 1 }),
  malformedFixture('deep_scope_undone', '4000 units deleted 2000 lists deep in the scope, undone, redone',
    deepScope(2000, 4000), { tracked: 1 }),
  malformedFixture('nested_map_chain_replaced_too_deep', '5000 nested maps, the outermost replaced', [
    nestedChain(5, 5000, true), rootEntry(6)]),
  malformedFixture('surrogate_pairs_split', 'deletes splitting surrogate pairs near either end of a string', [
    rawUpdate(5, 0, [rootString('\u{1F600}'.repeat(4))]), deleteRanges(5, [[1, 1], [6, 1]])]),
  malformedFixture('long_string_split_by_deletes', 'a 40 000-unit string split by 4000 deleted ranges', [
    rawUpdate(5, 0, [rootString('x'.repeat(40000))]), deleteRanges(5, range(4000, (i) => [i * 10 + 5, 1]))]),
  malformedFixture('long_run_merged', '15 000 one-unit items typed one after another, merged into one', [
    rawUpdate(5, 0, [rootString('x'), ...range(14999, (i) => stringAfter(5, i, 'x'))])]),
  malformedFixture('any_run_split_by_origins', 'a run of 20 000 any values split by 2000 items, merged back', [
    rawUpdate(5, 0, [rootAnyFalse(20000)]), rawUpdate(6, 0, range(2000, (i) => stringAfter(5, i * 10 + 5, 'y')))]),
  malformedFixture('long_string_split_by_origins', 'a 40 000-unit string split by 4000 items, merged back', [
    rawUpdate(5, 0, [rootString('x'.repeat(40000))]), rawUpdate(6, 0, range(4000, (i) => stringAfter(5, i * 10 + 5, 'y')))]),
]

const out = {
  meta: { yjsVersion: YJS_VERSION, format: 'v1', key: KEY, generatedBy: 'fixtures/generate.mjs' },
  encode, merge, converge, diff, incremental, sticky, semantic, array, map, xml, containerConverge, fuzz, malformed,
}

const here = dirname(fileURLToPath(import.meta.url))
const dest = join(here, '..', 'Tests', 'YSwiftTests', 'Fixtures')
mkdirSync(dest, { recursive: true })
writeFileSync(join(dest, 'golden_v13_6_31.json'), JSON.stringify(out, null, 2) + '\n')

const count =
  encode.length + merge.length + converge.length + diff.length + incremental.length + sticky.length
  + semantic.length + array.length + map.length + xml.length + containerConverge.length + fuzz.length
  + malformed.length
console.log(`wrote ${count} fixtures (yjs ${YJS_VERSION}) -> Tests/YSwiftTests/Fixtures/golden_v13_6_31.json`)

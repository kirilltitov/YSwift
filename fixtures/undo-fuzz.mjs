// Differential undo/redo fuzz generator (pinned JS-Yjs 13.6.31).
//
// Every scenario is a list of steps (local transactions, UndoManager undo/redo/stopCapturing,
// UndoManager creation/destruction, and state exchange between documents). The generator runs
// each scenario in Yjs and records, after every step, the update bytes the touched document
// emitted, its state vector, the text and delta of every root and the canUndo/canRedo of its
// undo managers, plus every document's final encoded state. The Swift runner
// (UndoFuzzTests.swift) replays the same steps and reports the first divergent step.
//
// Scenarios are normalised while they run: indices are clamped to the current text and empty
// operations are dropped, so any subsequence of steps is again a valid scenario (used by the
// minimiser) and the recorded ops are exactly what both sides execute.
//
// Usage: node undo-fuzz.mjs --suite --out ../Tests/YSwiftTests/Fixtures/undo_fuzz_v13_6_31.json
//        node undo-fuzz.mjs [--from N] [--count N] [--noformat] [--singlekey] [--server] [--out path]
// --noformat drops formatting attributes and format ops; --singlekey keeps one key per attribute
// set; --server uses only the sheets-api-shaped template, whose browser document is a JS peer (the
// Swift runner feeds its recorded bytes). A larger corpus runs through UNDO_FUZZ_FIXTURE, e.g.
//   node undo-fuzz.mjs --from 1000 --count 3000 --noformat --out /tmp/nf.json
//   UNDO_FUZZ_FIXTURE=/tmp/nf.json swift test --filter UndoFuzz

import * as Y from 'yjs'
import { writeFileSync } from 'node:fs'

export const YJS_VERSION = '13.6.31'
const b64 = (u8) => Buffer.from(u8).toString('base64')

export function makeRng(seed) {
  let s = seed >>> 0
  return () => {
    s = (s + 0x6d2b79f5) >>> 0
    let t = Math.imul(s ^ (s >>> 15), 1 | s)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const LONG_TIMEOUT = 3_600_000

/** Live Yjs model of one scenario. `apply` normalises a step, executes it and returns its record. */
export class Sim {
  constructor(config) {
    this.config = config
    this.docs = config.docs.map((d) => {
      const doc = new Y.Doc({ gc: d.gc })
      doc.clientID = d.client
      // Type every root up front, as YSwift's roots always are. A Yjs root first created by a
      // remote update is a plain AbstractType; upgrading it with getText later drops the
      // "has formatting" state (search markers come back, remote formatting cleanup is skipped).
      for (const root of config.roots) doc.getText(root)
      const log = []
      doc.on('update', (u) => log.push(b64(u)))
      return { doc, log }
    })
    this.ums = config.ums.map(() => null)
    this.created = new Set()
    config.ums.forEach((spec, i) => {
      if (!spec.late) this.createUM(i)
    })
  }

  createUM(i) {
    const spec = this.config.ums[i]
    const { doc } = this.docs[spec.doc]
    this.created.add(i)
    // A fresh Set per manager: Yjs adds the manager itself to the set it is given.
    this.ums[i] = new Y.UndoManager(doc.getText(spec.root), {
      trackedOrigins: new Set(spec.origins),
      captureTimeout: spec.timeout,
    })
  }

  len(d, root) {
    return this.docs[d].doc.getText(root).length
  }

  normalizeOp(d, o) {
    const len = this.len(d, o.root)
    switch (o.op) {
      case 'insert':
      case 'embed':
      case 'embedtype':
        return { ...o, index: Math.min(o.index, len) }
      case 'nested':
        return o
      case 'delete':
      case 'format': {
        if (len === 0) return null
        const index = Math.min(o.index, len - 1)
        const length = Math.min(o.length, len - index)
        if (length <= 0) return null
        return { ...o, index, length }
      }
    }
    throw new Error(`unknown op ${o.op}`)
  }

  applyOp(d, o) {
    const t = this.docs[d].doc.getText(o.root)
    switch (o.op) {
      case 'insert': t.insert(o.index, o.text, o.attributes ?? undefined); break
      case 'embed': t.insertEmbed(o.index, o.embed, o.attributes ?? undefined); break
      case 'delete': t.delete(o.index, o.length); break
      case 'format': t.format(o.index, o.length, o.attributes); break
      // Nested types, for JS peers only (YSwift has no API to create them): a Y.Map or Y.Array
      // embedded in the text, and edits inside the nth embedded type (by `path` for deeper ones).
      case 'embedtype': t.insertEmbed(o.index, o.kind === 'map' ? new Y.Map() : new Y.Array()); break
      case 'nested': {
        let type = t.toDelta().filter((op) => op.insert instanceof Y.AbstractType)[o.nth].insert
        for (const i of o.path ?? []) type = type.get(i)
        if (o.set !== undefined) type.set(o.set, o.value instanceof Array ? new Y.Map() : o.value)
        if (o.del !== undefined) type instanceof Y.Map ? type.delete(o.del) : type.delete(o.del, 1)
        if (o.push !== undefined) type.push([o.push === 'map' ? new Y.Map() : o.push])
        break
      }
    }
  }

  /** Returns `{ step, rec }` or null when the step became a no-op. */
  apply(step) {
    switch (step.k) {
      case 'tx': {
        const { doc } = this.docs[step.doc]
        const ops = []
        doc.transact(() => {
          for (const raw of step.ops) {
            const o = this.normalizeOp(step.doc, raw)
            if (o === null) continue
            this.applyOp(step.doc, o)
            ops.push(o)
          }
        }, step.origin)
        if (ops.length === 0 && this.docs[step.doc].log.length === this.mark(step.doc)) return null
        return this.finish({ ...step, ops }, [step.doc])
      }
      case 'undo':
      case 'redo': {
        const um = this.ums[step.um]
        if (um === null) return null
        step.k === 'undo' ? um.undo() : um.redo()
        return this.finish(step, [this.config.ums[step.um].doc])
      }
      case 'stop': {
        const um = this.ums[step.um]
        if (um === null) return null
        um.stopCapturing()
        return this.finish(step, [this.config.ums[step.um].doc])
      }
      case 'newum': {
        if (this.created.has(step.um) || !this.config.ums[step.um].late) return null
        this.createUM(step.um)
        return this.finish(step, [this.config.ums[step.um].doc])
      }
      case 'destroy': {
        const um = this.ums[step.um]
        if (um === null) return null
        um.destroy()
        this.ums[step.um] = null
        return this.finish(step, [this.config.ums[step.um].doc])
      }
      case 'sync': {
        if (step.from === step.to) return null
        const from = this.docs[step.from].doc
        const to = this.docs[step.to].doc
        const sent = Y.encodeStateAsUpdate(from, Y.encodeStateVector(to))
        Y.applyUpdate(to, sent, step.origin)
        return this.finish(step, [step.to], b64(sent))
      }
    }
    throw new Error(`unknown step ${step.k}`)
  }

  mark(d) {
    return (this.marks ?? [])[d] ?? 0
  }

  finish(step, touched, sent) {
    const rec = { docs: touched.map((d) => this.snapshot(d)) }
    if (sent !== undefined) rec.sent = sent
    this.marks = this.docs.map((x) => x.log.length)
    return { step, rec }
  }

  snapshot(d) {
    const { doc, log } = this.docs[d]
    const from = this.mark(d)
    const texts = {}
    const deltas = {}
    for (const root of this.config.roots) {
      const t = doc.getText(root)
      texts[root] = t.toString()
      // YSwift's toDelta leaves nested types out; scenarios with them compare bytes and text only.
      if (!this.config.nodelta) deltas[root] = JSON.stringify(t.toDelta())
    }
    const ums = []
    this.config.ums.forEach((spec, i) => {
      if (spec.doc !== d || this.ums[i] === null) return
      ums.push([i, this.ums[i].canUndo(), this.ums[i].canRedo()])
    })
    return { d, updates: log.slice(from), sv: b64(Y.encodeStateVector(doc)), texts, deltas, ums }
  }

  final() {
    return this.docs.map(({ doc }) => ({ state: b64(Y.encodeStateAsUpdate(doc)), sv: b64(Y.encodeStateVector(doc)) }))
  }
}

/** Runs `steps` against `config`, returning the normalised scenario with its Yjs expectations. */
export function record(name, config, steps) {
  const sim = new Sim(config)
  const out = []
  const expect = []
  for (const s of steps) {
    const r = sim.apply(s)
    if (r === null) continue
    out.push(r.step)
    expect.push(r.rec)
  }
  return { name, ...config, steps: out, expect, final: sim.final() }
}

// ---------------------------------------------------------------------------------------------
// Random scenario generation. Steps are generated against a live Sim so indices are sensible.

const ALPHABET = 'abcdefghij'
// --noformat: no formatting attributes anywhere (isolates undo/redo from YText formatting paths).
let NOFORMAT = false
export function setNoFormat(value) {
  NOFORMAT = value
}
// --singlekey: every formatting attribute set has one key. YSwift writes the format items of a
// multi-key set in sorted key order (its Attributes dictionary has no key order), Yjs in object key
// order; one key per set keeps that known YText difference out of the undo/redo corpus.
let SINGLEKEY = false
export function setSingleKey(value) {
  SINGLEKEY = value
}
const pick = (rng, xs) => xs[Math.floor(rng() * xs.length)]
const int = (rng, lo, hi) => lo + Math.floor(rng() * (hi - lo + 1))

function randText(rng) {
  if (rng() < 0.03) return pick(rng, ['😀', 'x😀', '😀y'])
  let s = ''
  for (let i = 0, n = int(rng, 1, 5); i < n; i++) s += pick(rng, ALPHABET.split(''))
  return s
}

function randAttrs(rng) {
  if (SINGLEKEY) return pick(rng, [{ bold: true }, { italic: true }, { bold: null }, { color: 'red' }, { link: 'https://x.test' }])
  const r = rng()
  if (r < 0.35) return { bold: true }
  if (r < 0.5) return { italic: true }
  if (r < 0.6) return { bold: null }
  if (r < 0.7) return { color: pick(rng, ['red', 'blue']) }
  if (r < 0.8) return { bold: true, italic: true }
  if (r < 0.9) return { italic: null }
  return { link: 'https://x.test' }
}

/** A stored segment format as PageHydration.attributes builds it (true / string values only). */
function hydrationAttrs(rng) {
  const out = {}
  for (const k of ['bold', 'italic', 'strike', 'underline', 'code']) if (rng() < 0.3) out[k] = true
  if (rng() < 0.2) out.color = pick(rng, ['red', 'blue'])
  if (rng() < 0.15) out.background = 'yellow'
  if (rng() < 0.1) out.link = 'https://x.test'
  if (Object.keys(out).length === 0) out.bold = true
  if (SINGLEKEY) return Object.fromEntries(Object.entries(out).slice(0, 1))
  // YSwift's Attributes is an unordered dictionary and it writes several keys sorted; Yjs follows
  // object key order. Sorting here keeps that known API-level difference out of the fuzz.
  return Object.fromEntries(Object.entries(out).sort(([a], [b]) => (a < b ? -1 : 1)))
}

function randOp(rng, sim, d, roots) {
  const root = pick(rng, roots)
  const len = sim.len(d, root)
  const r = rng()
  if (len === 0 || r < 0.45) {
    const o = { op: 'insert', root, index: int(rng, 0, len), text: randText(rng) }
    const a = rng()
    if (NOFORMAT) return o
    if (a < 0.15) o.attributes = randAttrs(rng)
    else if (a < 0.2) o.attributes = {}
    return o
  }
  if (r < 0.78) {
    const index = int(rng, 0, len - 1)
    return { op: 'delete', root, index, length: int(rng, 1, Math.min(len - index, rng() < 0.7 ? 3 : 8)) }
  }
  if (r < 0.95 && !NOFORMAT) {
    const index = int(rng, 0, len - 1)
    return { op: 'format', root, index, length: int(rng, 1, len - index), attributes: randAttrs(rng) }
  }
  const o = { op: 'embed', root, index: int(rng, 0, len), embed: { b: int(rng, 0, 9) } }
  if (rng() < 0.3 && !NOFORMAT) o.attributes = randAttrs(rng)
  return o
}

function randClients(rng, n) {
  const ids = new Set()
  while (ids.size < n) ids.add(rng() < 0.5 ? int(rng, 1, 20) : int(rng, 1, 0xffffffff))
  return [...ids]
}

/** Pushes a step through the sim, keeping it only when it did something. */
function push(sim, list, step) {
  const r = sim.apply(step)
  if (r !== null) list.push(r.step)
}

function typingBurst(rng, sim, steps, d, root, origin) {
  let pos = int(rng, 0, sim.len(d, root))
  for (let i = 0, n = int(rng, 2, 6); i < n; i++) {
    if (i > 0 && rng() < 0.15 && pos > 0) {
      push(sim, steps, { k: 'tx', doc: d, origin, ops: [{ op: 'delete', root, index: pos - 1, length: 1 }] })
      pos -= 1
      continue
    }
    const ch = pick(rng, ALPHABET.split(''))
    push(sim, steps, { k: 'tx', doc: d, origin, ops: [{ op: 'insert', root, index: pos, text: ch }] })
    pos += 1
  }
}

function randomScenario(seed) {
  const rng = makeRng(seed)
  const numDocs = rng() < 0.35 ? 1 : rng() < 0.85 ? 2 : 3
  const clients = randClients(rng, numDocs)
  const docs = clients.map((client) => ({ client, gc: rng() < 0.85 }))
  const rootCount = rng() < 0.45 ? 1 : rng() < 0.65 ? 2 : 3
  const roots = ['a', 'b', 'c'].slice(0, rootCount)
  const ums = []
  for (let d = 0; d < numDocs; d++) {
    for (let i = 0, n = d === 0 ? int(rng, 1, 3) : int(rng, 0, 2); i < n; i++) {
      const r = rng()
      const origins = r < 0.6 ? ['u'] : r < 0.75 ? ['v'] : ['u', 'v']
      ums.push({ doc: d, root: pick(rng, roots), origins, timeout: rng() < 0.8 ? 0 : LONG_TIMEOUT })
    }
  }
  const config = { seed, docs, roots, ums }
  const sim = new Sim(config)
  const steps = []

  if (rng() < 0.6) {
    // Untracked baseline content, shared with every document.
    for (let i = 0, n = int(rng, 1, 3); i < n; i++) {
      const ops = []
      for (let j = 0, m = int(rng, 1, 3); j < m; j++) ops.push(randOp(rng, sim, 0, roots))
      push(sim, steps, { k: 'tx', doc: 0, origin: null, ops })
    }
    for (let d = 1; d < numDocs; d++) push(sim, steps, { k: 'sync', from: 0, to: d, origin: null })
  }

  const umsOf = (pred) => ums.map((u, i) => i).filter((i) => sim.ums[i] !== null && pred(sim.ums[i]))
  for (let i = 0, n = int(rng, 8, 40); i < n; i++) {
    const r = rng()
    if (r < 0.35) {
      const d = int(rng, 0, numDocs - 1)
      const o = rng()
      const origin = o < 0.55 ? 'u' : o < 0.7 ? 'v' : o < 0.85 ? null : 'x'
      const ops = []
      for (let j = 0, m = rng() < 0.8 ? int(rng, 1, 3) : int(rng, 4, 8); j < m; j++) ops.push(randOp(rng, sim, d, roots))
      push(sim, steps, { k: 'tx', doc: d, origin, ops })
    } else if (r < 0.45) {
      const d = int(rng, 0, numDocs - 1)
      typingBurst(rng, sim, steps, d, pick(rng, roots), rng() < 0.85 ? 'u' : null)
    } else if (r < 0.65) {
      const ready = umsOf((u) => u.canUndo())
      const um = ready.length > 0 && rng() < 0.85 ? pick(rng, ready) : int(rng, 0, ums.length - 1)
      push(sim, steps, { k: 'undo', um })
    } else if (r < 0.8) {
      const ready = umsOf((u) => u.canRedo())
      const um = ready.length > 0 && rng() < 0.85 ? pick(rng, ready) : int(rng, 0, ums.length - 1)
      push(sim, steps, { k: 'redo', um })
    } else if (r < 0.95) {
      if (numDocs < 2) continue
      const from = int(rng, 0, numDocs - 1)
      const to = (from + int(rng, 1, numDocs - 1)) % numDocs
      push(sim, steps, { k: 'sync', from, to, origin: rng() < 0.4 ? 'u' : null })
    } else {
      push(sim, steps, { k: 'stop', um: int(rng, 0, ums.length - 1) })
    }
  }
  return record(`${NOFORMAT ? 'nf' : SINGLEKEY ? 'sk' : ''}random_${seed}`, config, steps)
}

/**
 * The sheets-api shapes: a browser document B edits (typing, cuts through merged runs, formats,
 * several roots), the server S receives the change with a tracked origin through fresh
 * per-root undo managers, undoes them in reverse order and redoes them forward
 * (PageTextHistoryReplay.derive), or replaces the roots locally and undoes that
 * (rebasedHistoryUpdates); the server's result flows back to the browser, which keeps editing.
 */
function serverScenario(seed) {
  const rng = makeRng(seed)
  const clients = randClients(rng, 2)
  // The browser document is JS-Yjs in production: the Swift runner feeds the server the bytes
  // Yjs produced instead of replaying the browser's edits in YSwift.
  const docs = clients.map((client, i) => (i === 0 ? { client, gc: true, js: true } : { client, gc: true }))
  const rootCount = rng() < 0.4 ? 1 : rng() < 0.7 ? 2 : 3
  const roots = ['a', 'b', 'c'].slice(0, rootCount)
  const rounds = int(rng, 1, 4)
  const ums = []
  const plan = []
  for (let round = 0; round < rounds; round++) {
    const ids = roots.map((root) => {
      ums.push({ doc: 1, root, origins: ['r'], timeout: 0, late: true })
      return ums.length - 1
    })
    plan.push({ ids, reseed: rng() < (HYDRATION ? 0.5 : 0.25) })
  }
  const config = { seed, docs, roots, ums }
  const sim = new Sim(config)
  const steps = []
  const B = 0
  const S = 1

  for (const root of roots) {
    for (let i = 0, n = int(rng, 1, 3); i < n; i++) {
      if (rng() < 0.5) typingBurst(rng, sim, steps, B, root, 'b')
      else push(sim, steps, { k: 'tx', doc: B, origin: 'b', ops: [randOp(rng, sim, B, [root])] })
    }
  }
  push(sim, steps, { k: 'sync', from: B, to: S, origin: null })

  for (const { ids, reseed } of plan) {
    for (const um of ids) push(sim, steps, { k: 'newum', um })
    if (reseed) {
      // PageHydration.replace: delete everything, insert the plain text at 0, then format each
      // stored segment (contiguous, non-overlapping) in order.
      const ops = []
      for (const root of roots) {
        if (rng() < 0.5) continue
        const len = sim.len(S, root)
        if (len > 0) ops.push({ op: 'delete', root, index: 0, length: len })
        const text = randText(rng) + randText(rng)
        ops.push({ op: 'insert', root, index: 0, text })
        if (NOFORMAT) continue
        let at = 0
        while (at < text.length) {
          const n = int(rng, 1, text.length - at)
          if (rng() < 0.6) ops.push({ op: 'format', root, index: at, length: n, attributes: hydrationAttrs(rng) })
          at += n
        }
      }
      if (ops.length > 0) push(sim, steps, { k: 'tx', doc: S, origin: 'r', ops })
      for (const um of [...ids].reverse()) push(sim, steps, { k: 'undo', um })
    } else {
      for (let i = 0, n = int(rng, 1, 3); i < n; i++) {
        if (rng() < 0.4) typingBurst(rng, sim, steps, B, pick(rng, roots), 'b')
        else {
          const ops = []
          for (let j = 0, m = int(rng, 1, 4); j < m; j++) ops.push(randOp(rng, sim, B, roots))
          push(sim, steps, { k: 'tx', doc: B, origin: 'b', ops })
        }
      }
      push(sim, steps, { k: 'sync', from: B, to: S, origin: 'r' })
      for (const um of [...ids].reverse()) push(sim, steps, { k: 'undo', um })
      for (const um of ids) push(sim, steps, { k: 'redo', um })
    }
    for (const um of ids) push(sim, steps, { k: 'destroy', um })
    if (rng() < 0.7) push(sim, steps, { k: 'sync', from: S, to: B, origin: null })
    if (rng() < 0.5) {
      push(sim, steps, { k: 'tx', doc: B, origin: 'b', ops: [randOp(rng, sim, B, roots)] })
      push(sim, steps, { k: 'sync', from: B, to: S, origin: null })
    }
  }
  return record(`${NOFORMAT ? 'nf' : SINGLEKEY ? 'sk' : ''}${HYDRATION ? 'srv' : 'server'}_${seed}`, config, steps)
}

// --server: every seed uses the sheets-api server template, with more PageHydration reseeds.
let HYDRATION = false
export function setServerOnly(value) {
  HYDRATION = value
}

export function scenario(seed) {
  return HYDRATION || seed % 3 === 0 ? serverScenario(seed) : randomScenario(seed)
}

// Minimised divergences of YSwift 0.4.0 from Yjs 13.6.31 undo/redo, replayed first by --suite.
const REPROS = {
  redo_anchors_before_original: {"docs":[{"client":1,"gc":true}],"roots":["a"],"ums":[{"doc":0,"root":"a","origins":["u"],"timeout":0}],"steps":[{"k":"tx","doc":0,"origin":"u","ops":[{"op":"insert","root":"a","index":0,"text":"b"}]},{"k":"undo","um":0},{"k":"redo","um":0}]},
  undo_recreates_before_original: {"docs":[{"client":2,"gc":true,"js":true},{"client":1,"gc":true}],"roots":["b"],"ums":[{"doc":1,"root":"b","origins":["r"],"timeout":0}],"steps":[{"k":"tx","doc":0,"origin":"b","ops":[{"op":"insert","root":"b","index":0,"text":"z"}]},{"k":"sync","from":0,"to":1,"origin":null},{"k":"tx","doc":0,"origin":"b","ops":[{"op":"delete","root":"b","index":0,"length":1}]},{"k":"sync","from":0,"to":1,"origin":"r"},{"k":"undo","um":0}]},
  partly_covered_item_is_split: {"docs":[{"client":1,"gc":true}],"roots":["c"],"ums":[{"doc":0,"root":"c","origins":["u"],"timeout":0}],"steps":[{"k":"tx","doc":0,"origin":"u","ops":[{"op":"insert","root":"c","index":0,"text":"jh"},{"op":"delete","root":"c","index":1,"length":1}]},{"k":"undo","um":0},{"k":"redo","um":0}]},
  merged_run_is_split_on_redo: {"docs":[{"client":1,"gc":true}],"roots":["a"],"ums":[{"doc":0,"root":"a","origins":["u"],"timeout":0}],"steps":[{"k":"tx","doc":0,"origin":"u","ops":[{"op":"insert","root":"a","index":0,"text":"j"}]},{"k":"undo","um":0},{"k":"tx","doc":0,"origin":"u","ops":[{"op":"insert","root":"a","index":0,"text":"h"}]},{"k":"undo","um":0},{"k":"redo","um":0}]},
  other_root_is_out_of_scope: {"docs":[{"client":1,"gc":true}],"roots":["a","b"],"ums":[{"doc":0,"root":"a","origins":["u"],"timeout":0}],"steps":[{"k":"tx","doc":0,"origin":"u","ops":[{"op":"insert","root":"b","index":0,"text":"e"},{"op":"insert","root":"a","index":0,"text":"f"}]},{"k":"undo","um":0}]},
  undo_follows_redone_insertion: {"docs":[{"client":1,"gc":true}],"roots":["b"],"ums":[{"doc":0,"root":"b","origins":["u"],"timeout":0}],"steps":[{"k":"tx","doc":0,"origin":"u","ops":[{"op":"insert","root":"b","index":0,"text":"d"}]},{"k":"tx","doc":0,"origin":"u","ops":[{"op":"delete","root":"b","index":0,"length":1}]},{"k":"undo","um":0},{"k":"undo","um":0}]},
  redo_follows_delete_set_order: {"docs":[{"client":1,"gc":true}],"roots":["a"],"ums":[{"doc":0,"root":"a","origins":["u"],"timeout":3600000}],"steps":[{"k":"tx","doc":0,"origin":"u","ops":[{"op":"insert","root":"a","index":0,"text":"gge"}]},{"k":"tx","doc":0,"origin":"u","ops":[{"op":"delete","root":"a","index":1,"length":1}]},{"k":"undo","um":0},{"k":"redo","um":0}]},
  split_keeps_keep_flag: {"docs":[{"client":1,"gc":true}],"roots":["a"],"ums":[{"doc":0,"root":"a","origins":["u"],"timeout":3600000}],"steps":[{"k":"tx","doc":0,"origin":"u","ops":[{"op":"insert","root":"a","index":0,"text":"ha"}]},{"k":"tx","doc":0,"origin":"u","ops":[{"op":"delete","root":"a","index":1,"length":1}]},{"k":"undo","um":0},{"k":"redo","um":0}]},
  split_keeps_redone_link: {"docs":[{"client":1,"gc":true}],"roots":["a"],"ums":[{"doc":0,"root":"a","origins":["u"],"timeout":0}],"steps":[{"k":"tx","doc":0,"origin":"u","ops":[{"op":"insert","root":"a","index":0,"text":"ag"}]},{"k":"tx","doc":0,"origin":"u","ops":[{"op":"insert","root":"a","index":2,"text":"h"}]},{"k":"tx","doc":0,"origin":"u","ops":[{"op":"delete","root":"a","index":1,"length":2}]},{"k":"undo","um":0},{"k":"undo","um":0}]},
  split_only_transaction_merges_back: {"docs":[{"client":1,"gc":true}],"roots":["a"],"ums":[{"doc":0,"root":"a","origins":["u"],"timeout":3600000},{"doc":0,"root":"a","origins":["u"],"timeout":0}],"steps":[{"k":"tx","doc":0,"origin":"u","ops":[{"op":"insert","root":"a","index":0,"text":"d"}]},{"k":"tx","doc":0,"origin":"u","ops":[{"op":"insert","root":"a","index":1,"text":"e"}]},{"k":"undo","um":0},{"k":"undo","um":1},{"k":"redo","um":0}]},
  remote_content_deleted_orders_delete_set: {"docs":[{"client":1,"gc":true,"js":true},{"client":2,"gc":true}],"roots":["a"],"ums":[{"doc":1,"root":"a","origins":["r"],"timeout":0}],"steps":[{"k":"tx","doc":0,"origin":"b","ops":[{"op":"insert","root":"a","index":0,"text":"a"}]},{"k":"sync","from":0,"to":1,"origin":null},{"k":"tx","doc":1,"origin":null,"ops":[{"op":"insert","root":"a","index":1,"text":"x"}]},{"k":"sync","from":1,"to":0,"origin":null},{"k":"tx","doc":0,"origin":"b","ops":[{"op":"insert","root":"a","index":2,"text":"y"},{"op":"delete","root":"a","index":0,"length":3}]},{"k":"sync","from":0,"to":1,"origin":"r"},{"k":"undo","um":0}]},
}

// The undo/redo parity audit scenarios (S1b–S15): each pins one proven departure of YSwift 0.4.0
// from Yjs 13.6.31 with the exact shape it was found in. Ops helpers keep them readable.
const ins = (root, index, text, attributes) => ({ op: 'insert', root, index, text, ...(attributes ? { attributes } : {}) })
const del = (root, index, length) => ({ op: 'delete', root, index, length })
const fmt = (root, index, length, attributes) => ({ op: 'format', root, index, length, attributes })
const tx = (doc, origin, ...ops) => ({ k: 'tx', doc, origin, ops })
const sync = (from, to, origin = null) => ({ k: 'sync', from, to, origin })
const undo = (um) => ({ k: 'undo', um })
const redo = (um) => ({ k: 'redo', um })
const one = (client = 1) => [{ client, gc: true }]
const um = (root, timeout = 0, doc = 0) => ({ doc, root, origins: ['o'], timeout })
// Nested types, run by a Yjs peer (`peer`) against the Swift server document.
const et = (index, kind) => ({ op: 'embedtype', root: 't', index, kind })
const nset = (nth, set, value, path) => ({ op: 'nested', root: 't', nth, set, value, ...(path ? { path } : {}) })
const npush = (nth, push) => ({ op: 'nested', root: 't', nth, push })
const peer = (client) => ({ client, gc: true, js: true })
const server = { client: 9, gc: true }
const AUDIT = {
  // Two adjacent deleted items of two clients are re-created in one undo.
  audit_s1b_adjacent_recreations: {
    docs: [...one(1), ...one(2)], roots: ['t'], ums: [um('t')],
    steps: [tx(0, null, ins('t', 0, 'ac')), sync(0, 1), tx(1, null, ins('t', 1, 'b')), sync(1, 0),
      tx(0, 'o', del('t', 1, 2)), undo(0)],
  },
  // A tracked insertion that merges into the run to its left is undone alone.
  audit_s2_merged_insertion: {
    docs: one(), roots: ['t'], ums: [um('t')],
    steps: [tx(0, null, ins('t', 0, 'ab')), tx(0, 'o', ins('t', 2, 'c')), undo(0), redo(0)],
  },
  // The same with the run continued by a Yjs peer whose update the server applies tracked.
  audit_s2r_remote_run_continuation: {
    docs: [{ client: 1, gc: true, js: true }, { client: 9, gc: true }], roots: ['t'], ums: [um('t', 0, 1)],
    steps: [tx(0, 'b', ins('t', 0, 'ab')), sync(0, 1), tx(0, 'b', ins('t', 2, 'c')), sync(0, 1, 'o'), undo(0),
      redo(0)],
  },
  // Kept deletions of two steps merge into one item; undoing the later step restores only its part.
  audit_s3_merged_kept_deletions: {
    docs: one(), roots: ['t'], ums: [um('t')],
    steps: [tx(0, null, ins('t', 0, 'abc')), tx(0, 'o', del('t', 1, 1)), tx(0, 'o', del('t', 1, 1)), undo(0)],
  },
  // One tracked transaction over two roots, one manager per root (derive: undo reversed, redo forward).
  audit_s5_two_roots: {
    docs: one(), roots: ['A', 'B'], ums: [um('A'), um('B')],
    steps: [tx(0, null, ins('A', 0, 'aa')), tx(0, null, ins('B', 0, 'bb')), tx(0, 'o', ins('A', 1, 'X'), del('B', 0, 1)),
      undo(1), undo(0), redo(0), redo(1)],
  },
  audit_s5b_two_roots_deletions: {
    docs: one(), roots: ['A', 'B'], ums: [um('A'), um('B')],
    steps: [tx(0, null, ins('A', 0, 'aa')), tx(0, null, ins('B', 0, 'bb')), tx(0, 'o', del('A', 0, 1), del('B', 0, 1)),
      undo(1), undo(0), redo(0), redo(1)],
  },
  audit_s5c_two_roots_insertions: {
    docs: one(), roots: ['A', 'B'], ums: [um('A'), um('B')],
    steps: [tx(0, null, ins('A', 0, 'aa')), tx(0, null, ins('B', 0, 'bb')), tx(0, 'o', ins('A', 1, 'X'), ins('B', 1, 'Y')),
      undo(1), undo(0), redo(0), redo(1)],
  },
  // Redo re-creates two inserted items in clock order, not deletion order.
  audit_s6_two_insertions: {
    docs: one(), roots: ['t'], ums: [um('t')],
    steps: [tx(0, null, ins('t', 0, 'xy')), tx(0, 'o', ins('t', 0, 'A'), ins('t', 3, 'B')), undo(0), redo(0)],
  },
  // A formatted insertion: format start, text and format end are re-created in clock order.
  audit_s6f_formatted_insertion: {
    docs: one(), roots: ['t'], ums: [um('t')],
    steps: [tx(0, null, ins('t', 0, 'xy')), tx(0, 'o', ins('t', 1, 'B', { bold: true })), undo(0), redo(0)],
  },
  audit_s6d_two_client_deletion_cycle: {
    docs: [...one(1), ...one(2)], roots: ['t'], ums: [um('t')],
    steps: [tx(0, null, ins('t', 0, 'ac')), sync(0, 1), tx(1, null, ins('t', 1, 'b')), sync(1, 0),
      tx(0, 'o', del('t', 0, 3)), undo(0), redo(0), undo(0)],
  },
  // Deletions merged into one stack item (captureTimeout) are redone in clock order.
  audit_s7_merged_stack_item: {
    docs: one(), roots: ['t'], ums: [um('t', LONG_TIMEOUT)],
    steps: [tx(0, null, ins('t', 0, 'abc')), tx(0, 'o', del('t', 2, 1)), tx(0, 'o', del('t', 0, 1)), undo(0)],
  },
  // A kept deleted run split by a concurrent insertion keeps both halves for the undo.
  audit_s8_kept_run_split_remotely: {
    docs: [...one(1), ...one(2)], roots: ['t'], ums: [um('t')],
    steps: [tx(0, null, ins('t', 0, 'abc')), sync(0, 1), tx(0, 'o', del('t', 1, 2)), tx(1, null, ins('t', 2, 'Z')),
      sync(1, 0), undo(0)],
  },
  // Deletions outside the manager's root are not kept, so the GC drops their content.
  audit_s9_out_of_scope_deletion_is_collected: {
    docs: one(), roots: ['A', 'B'], ums: [um('A')],
    steps: [tx(0, null, ins('A', 0, 'aa')), tx(0, null, ins('B', 0, 'bb')), tx(0, 'o', del('A', 0, 1), del('B', 0, 1))],
  },
  // Redo after a concurrent insertion next to the undone item.
  audit_s11_redo_after_remote_insertion: {
    docs: [...one(1), ...one(2)], roots: ['t'], ums: [um('t')],
    steps: [tx(0, null, ins('t', 0, 'ab')), tx(0, 'o', ins('t', 1, 'X')), sync(0, 1), tx(1, null, ins('t', 2, 'Y')),
      undo(0), sync(1, 0), redo(0)],
  },
  // Undo and redo of a formatting change.
  audit_s12_format_change: {
    docs: one(), roots: ['t'], ums: [um('t')],
    steps: [tx(0, null, ins('t', 0, 'abcd')), tx(0, 'o', fmt('t', 1, 2, { bold: true })), undo(0), redo(0)],
  },
  // Undo of a deletion of formatted text re-creates format items and text in clock order.
  audit_s13_formatted_deletion: {
    docs: one(), roots: ['t'], ums: [um('t')],
    steps: [tx(0, null, ins('t', 0, 'ab')), tx(0, null, ins('t', 1, 'XY', { bold: true })), tx(0, 'o', del('t', 1, 2)),
      undo(0)],
  },
  // Insertions of two remote clients in one tracked update, in the store's client order.
  audit_s14_two_remote_clients: {
    docs: [...one(1), ...one(2), ...one(3), ...one(9)], roots: ['t'], ums: [um('t', 0, 3)],
    steps: [tx(0, null, ins('t', 0, 'ab')), sync(0, 1), sync(0, 2), sync(0, 3), tx(1, null, ins('t', 1, 'X')),
      tx(2, null, ins('t', 2, 'Y')), sync(1, 0), sync(2, 0), sync(0, 3, 'o'), undo(0), redo(0)],
  },
  // Nested types (from a Yjs peer) inside the undo scope: undo re-creates a deleted embedded map
  // and array, then their children inside the copies (redoItem's parent tracing), and redo deletes
  // the copies again.
  audit_nested_types_recreated_in_their_copies: {
    docs: [{ client: 1, gc: true, js: true }, { client: 9, gc: true }], roots: ['t'], ums: [um('t', 0, 1)], nodelta: true,
    steps: [tx(0, 'b', ins('t', 0, 'abc'), { op: 'embedtype', root: 't', index: 1, kind: 'map' },
      { op: 'embedtype', root: 't', index: 3, kind: 'array' }),
    tx(0, 'b', { op: 'nested', root: 't', nth: 0, set: 'k', value: 'v' }, { op: 'nested', root: 't', nth: 1, push: 'x' },
      { op: 'nested', root: 't', nth: 1, push: 'map' }, { op: 'nested', root: 't', nth: 1, push: 'y' }),
    tx(0, 'b', { op: 'nested', root: 't', nth: 1, path: [1], set: 'deep', value: 1 }),
    sync(0, 1), tx(0, 'b', del('t', 0, 5)), sync(0, 1, 'o'), undo(0), redo(0), undo(0)],
  },
  // A map key overwritten in a tracked step: undo restores the old value after the newer one
  // (redoItem's map branch skips right neighbours that the step inserted).
  audit_nested_map_value_restored: {
    docs: [{ client: 1, gc: true, js: true }, { client: 9, gc: true }], roots: ['t'], ums: [um('t', 0, 1)], nodelta: true,
    steps: [tx(0, 'b', ins('t', 0, 'ab'), { op: 'embedtype', root: 't', index: 1, kind: 'map' }),
      tx(0, 'b', { op: 'nested', root: 't', nth: 0, set: 'k', value: 'v1' }), sync(0, 1),
      tx(0, 'b', del('t', 0, 1), { op: 'nested', root: 't', nth: 0, set: 'k', value: 'v2' }), sync(0, 1, 'o'), undo(0),
      redo(0)],
  },
  // A newer untracked value of the key wins: undo cannot restore the old one (redoItem gives up).
  audit_nested_map_newer_value_wins: {
    docs: [{ client: 1, gc: true, js: true }, { client: 9, gc: true }], roots: ['t'], ums: [um('t', 0, 1)], nodelta: true,
    steps: [tx(0, 'b', ins('t', 0, 'ab'), { op: 'embedtype', root: 't', index: 1, kind: 'map' }),
      tx(0, 'b', { op: 'nested', root: 't', nth: 0, set: 'k', value: 'v1' }), sync(0, 1),
      tx(0, 'b', del('t', 0, 1), { op: 'nested', root: 't', nth: 0, set: 'k', value: 'v2' }), sync(0, 1, 'o'),
      tx(0, 'b', { op: 'nested', root: 't', nth: 0, set: 'k', value: 'v3' }), sync(0, 1), undo(0), redo(0)],
  },
  // A whole-text replace (PageHydration.replace) of text whose clocks are out of document order.
  audit_s15_replace_out_of_order_text: {
    docs: one(), roots: ['t'], ums: [um('t')],
    steps: [tx(0, null, ins('t', 0, 'ac')), tx(0, null, ins('t', 1, 'b')), tx(0, 'o', del('t', 0, 3), ins('t', 0, 'z')),
      undo(0), redo(0)],
  },
  // Collecting a deleted type turns its children into GC structs (Item.gc with parentGCd), which
  // the store's delete set covers; a child left behind without its parent cannot be encoded.
  audit_nested_gc_map_children: {
    docs: [peer(1), server], roots: ['t'], ums: [], nodelta: true,
    steps: [tx(0, 'b', ins('t', 0, 'ab'), et(1, 'map')), tx(0, 'b', nset(0, 'k', 'v1')), sync(0, 1),
      tx(0, 'b', del('t', 1, 1)), sync(0, 1)],
  },
  audit_nested_gc_recursive: {
    docs: [peer(1), server], roots: ['t'], ums: [], nodelta: true,
    steps: [tx(0, 'b', ins('t', 0, 'ab'), et(1, 'array')), tx(0, 'b', npush(0, 'x'), npush(0, 'map'), npush(0, 'y')),
      tx(0, 'b', nset(0, 'deep', 1, [1])), tx(0, 'b', nset(0, 'deep', 2, [1])), sync(0, 1), tx(0, 'b', del('t', 1, 1)),
      sync(0, 1)],
  },
  // Every value a key ever held is collected, and the server's next update still encodes.
  audit_nested_gc_overwritten_key: {
    docs: [peer(1), server], roots: ['t'], ums: [], nodelta: true,
    steps: [tx(0, 'b', ins('t', 0, 'ab'), et(1, 'map')), sync(0, 1), tx(0, 'b', nset(0, 'k', 'v1')), sync(0, 1),
      tx(0, 'b', nset(0, 'k', 'v2')), sync(0, 1), tx(0, 'b', del('t', 1, 1)), sync(0, 1), tx(1, null, ins('t', 1, 'z')),
      sync(1, 0)],
  },
  audit_nested_undo_under_remotely_deleted_parent: {
    docs: [peer(1), server], roots: ['t'], ums: [um('t', 0, 1)], nodelta: true,
    steps: [tx(0, 'b', ins('t', 0, 'ab'), et(1, 'map')), sync(0, 1), tx(0, 'b', nset(0, 'k', 'v1'), ins('t', 0, 'z')),
      sync(0, 1, 'o'), tx(0, 'b', del('t', 2, 1)), sync(0, 1), undo(0), redo(0)],
  },
  // A key set in a type the server has deleted changes no type Yjs reports: nothing is captured.
  audit_nested_update_in_deleted_type_untracked: {
    docs: [peer(1), server], roots: ['t'], ums: [um('t', 0, 1)], nodelta: true,
    steps: [tx(0, 'b', ins('t', 0, 'ab'), et(1, 'map')), sync(0, 1), tx(1, null, del('t', 1, 1)),
      tx(0, 'b', nset(0, 'k', 'v')), sync(0, 1, 'o'), undo(0)],
  },
}

export function suite(scenarios) {
  return { meta: { yjsVersion: YJS_VERSION, format: 'v1', generatedBy: 'undo-fuzz.mjs' }, scenarios }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const arg = (name, dflt) => {
    const i = process.argv.indexOf(name)
    return i < 0 ? dflt : process.argv[i + 1]
  }
  const from = Number(arg('--from', '1'))
  const count = Number(arg('--count', '200'))
  const out = arg('--out', 'undo_fuzz_v13_6_31.json')
  if (process.argv.includes('--noformat')) setNoFormat(true)
  if (process.argv.includes('--server')) setServerOnly(true)
  if (process.argv.includes('--singlekey')) setSingleKey(true)
  const scenarios = []
  if (process.argv.includes('--suite')) {
    // The committed regression corpus. Minimised repros and the audit scenarios first, one per
    // undo/redo divergence of YSwift 0.4.0 (see REPROS and AUDIT above), then seeded scenarios.
    for (const [name, spec] of [...Object.entries(REPROS), ...Object.entries(AUDIT)]) {
      const config = { seed: 0, docs: spec.docs, roots: spec.roots, ums: spec.ums, ...(spec.nodelta ? { nodelta: true } : {}) }
      scenarios.push(record(name, config, spec.steps))
    }
    setNoFormat(true)
    for (let seed = 1; seed <= 80; seed++) scenarios.push(scenario(seed))
    setServerOnly(true)
    for (let seed = 1; seed <= 60; seed++) scenarios.push(scenario(seed))
    // Formatted sheets-api shapes (typing with attributes, PageHydration reseeds), one key per set.
    setNoFormat(false)
    setSingleKey(true)
    for (let seed = 1; seed <= 60; seed++) scenarios.push(scenario(seed))
  } else {
    for (let seed = from; seed < from + count; seed++) scenarios.push(scenario(seed))
  }
  writeFileSync(out, JSON.stringify(suite(scenarios)))
  const steps = scenarios.reduce((n, s) => n + s.steps.length, 0)
  console.log(`wrote ${scenarios.length} scenarios (${steps} steps) to ${out}`)
}

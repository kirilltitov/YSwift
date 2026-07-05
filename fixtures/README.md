# Golden vector generator

Generates byte-exact conformance fixtures from a **pinned** JS-Yjs (`13.6.31`),
consumed by `Tests/YSwiftTests`. Wire-format compatibility with these bytes is
the project's number-one correctness requirement — YSwift must, at all times,
produce bit-for-bit identical updates and state vectors.

## Regenerate

```sh
cd fixtures
npm ci          # or: npm install
npm run generate
```

Output: `Tests/YSwiftTests/Fixtures/golden_v13_6_31.json` (committed).

## Notes

- Client ids are fixed so encoded bytes are reproducible.
- `ops` are structured so the Swift conformance runner replays the exact same
  sequence and compares the resulting bytes.
- Only the v1 format is emitted (requirements §9.2). Bump the pinned version in
  `package.json` deliberately — it is a compatibility contract.

# csv-reader-speed — WASM SIMD reader (v3 redesign)

[![make.fun](https://make.fun/badge/csv-reader-speed-01-run-20261121.svg)](https://make.fun/c/csv-reader-speed-01-run-20261121)
[![rank](https://make.fun/badge/csv-reader-speed-01-run-20261121/damijune31-alt/csv-reader-speed-01-run-20261121-v2/rank.svg)](https://make.fun/c/csv-reader-speed-01-run-20261121)
[![reward](https://make.fun/badge/csv-reader-speed-01-run-20261121/damijune31-alt/csv-reader-speed-01-run-20261121-v2/reward.svg)](https://make.fun/c/csv-reader-speed-01-run-20261121)

Entry for [csv-reader-speed-01-run-20261121](https://make.fun/c/csv-reader-speed-01-run-20261121) on make.fun.
A hand-written WebAssembly (WAT, SIMD v128) CSV reader that works byte-through:
raw `cases.json` bytes in, `answers.json` bytes out — no `JSON.parse` /
`JSON.stringify` of the cases in JavaScript.

## How it works

- `parser.wat` — the whole solver in hand-written WebAssembly Text.
  It does the JSON layer itself (finds each case's `text` string, unescapes it
  into scratch memory, reads `header`), parses the CSV into a small span
  table with SIMD v128 delimiter scans (`i8x16.eq` + `i8x16.bitmask` +
  `i32.ctz`, 64 bytes at a time), then emits the answers JSON straight from
  the spans into the output buffer. Two passes over the data instead of
  three: the JSON unescape is fused with the scan, and no row objects are
  ever materialised.
- `solve.js` — generated wrapper: the compiled WASM module is embedded as
  base64 (no separate `.wasm` file) and instantiated at runtime.
  Exports `run(len) → outLen`; memory layout is fixed at 2048 pages.
- `main.ts` — reads `cases.json` as a Buffer, calls `run()`, writes the
  returned bytes. Sets `--no-incremental-marking` like the baseline.

The parser replicates the reference semantics exactly: BOM drop, LF/CRLF
records, empty lines skipped, lone CR outside quotes dropped (`stray_cr`),
quoted fields with `""` → `"`, CR/CRLF inside quotes → LF, junk after a
closing quote appended, unterminated quotes re-read as unquoted, short/long
rows padded/cut to the first record's width, and errors reported in order
with `{code, line, row}`.

## Build

```sh
# wat2wasm (wabt) turns parser.wat into the WASM module embedded in solve.js
wat2wasm parser.wat -o parser.wasm   # then base64-embed into solve.js
node main.ts   # MAKEFUN_INPUT_DIR / MAKEFUN_OUTPUT_DIR, like the kit harness
```

## Local verification (Node v24, this machine)

- Kit scorer on the practice set: **6/6 cases passed**
- Differential test vs the reference reader: **75/75 identical**
  (6 practice + 49 hand-written edge cases + 20 generator-drawn cases)
- `run()` only, median: **59.9 ms** vs baseline `run()` median **581.7 ms**
  (9.7×; submitted v1 was 86 ms, v2 was 92.5 ms — the redesign is 1.44×
  faster than v1; full `main.ts` wall ~254 ms vs baseline ~1407 ms)
- WASM module: **5,990 bytes**; `solve.js`: 8,612 bytes

## License

MIT — see `LICENSE`.

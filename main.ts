// csv-reader-speed v2 driver: byte-through.
// Reads /input/cases.json as raw bytes, hands them to solve.js, writes the bytes it returns.
// No JSON.parse / JSON.stringify on the hot path: the WASM module reads the cases file
// and emits answers.json directly.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { setFlagsFromString } from 'node:v8';

// V8's incremental marking off, as the house baseline runs (the rules allow the same tuning).
setFlagsFromString('--no-incremental-marking');

/** solve.js, imported by its URL (a .js module carries no types) and typed by its contract. */
const { run } = (await import(new URL('./solve.js', import.meta.url).href)) as {
  run: (input: Uint8Array) => Uint8Array;
};

const INPUT_DIR = process.env.MAKEFUN_INPUT_DIR ?? '/input';
const OUTPUT_DIR = process.env.MAKEFUN_OUTPUT_DIR ?? '/output';

const input = readFileSync(join(INPUT_DIR, 'cases.json'));
const output = run(input);
writeFileSync(join(OUTPUT_DIR, 'answers.json'), output);

// Driver: read cases.json as raw bytes, answer them all with the WASM
// reader in solve.js, write answers.json as raw bytes. No JSON.parse /
// JSON.stringify of the cases anywhere in this program.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { setFlagsFromString } from 'node:v8';

setFlagsFromString('--no-incremental-marking');

const { run } = (await import(new URL('./solve.js', import.meta.url).href)) as {
  run: (input: Buffer) => Uint8Array;
};

const INPUT_DIR = process.env.MAKEFUN_INPUT_DIR ?? '/input';
const OUTPUT_DIR = process.env.MAKEFUN_OUTPUT_DIR ?? '/output';

const input = readFileSync(join(INPUT_DIR, 'cases.json'));
const answers = run(input);
writeFileSync(join(OUTPUT_DIR, 'answers.json'), answers);

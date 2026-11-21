#!/usr/bin/env node
// Compiles the in-page multiplayer demo (site/demo) to static web assets
// under site/public/demo/, which `astro build` then copies into dist/.
// Runs as the first step of `npm run build`.
//
// Preferred target is dart2wasm; dart2js is the fallback. The host page
// (site/src/pages/demo/index.astro) always loads /demo/boot.mjs — this
// script copies the matching boot template next to the compiled output.
//
// Requires the Dart SDK on PATH. If Dart is missing but assets from a
// previous build are already in place, the script warns and keeps them;
// otherwise it fails loudly.
import { execFileSync } from 'node:child_process';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  rmSync,
  statSync,
} from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const siteDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const demoDir = path.join(siteDir, 'demo');
const outDir = path.join(siteDir, 'public', 'demo');

const hasDart = (() => {
  try {
    execFileSync('dart', ['--version'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
})();

if (!hasDart) {
  if (existsSync(path.join(outDir, 'boot.mjs'))) {
    console.log('build-demo: dart not on PATH — keeping existing public/demo assets');
    process.exit(0);
  }
  console.error('build-demo: dart is not on PATH and no previous build exists');
  process.exit(1);
}

const kb = (p) => `${(statSync(p).size / 1024).toFixed(0)} KB`;
const run = (args, opts = {}) =>
  execFileSync('dart', args, { cwd: demoDir, stdio: 'inherit', ...opts });

rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });
run(['pub', 'get']);

let mode;
try {
  run(['compile', 'wasm', 'web/main.dart', '-o', path.join(outDir, 'main.wasm')]);
  copyFileSync(path.join(demoDir, 'web/boot.wasm.mjs'), path.join(outDir, 'boot.mjs'));
  mode = 'wasm';
} catch (e) {
  console.log('build-demo: dart2wasm failed, falling back to dart2js');
  run(['compile', 'js', 'web/main.dart', '-o', path.join(outDir, 'main.js'), '-O2']);
  copyFileSync(path.join(demoDir, 'web/boot.js.mjs'), path.join(outDir, 'boot.mjs'));
  mode = 'js';
}

// Source maps are debug aids, not deploy assets.
for (const f of readdirSync(outDir)) {
  if (f.endsWith('.map')) rmSync(path.join(outDir, f));
}

const assets = readdirSync(outDir).sort();
console.log(
  `build-demo: compiled with dart2${mode} -> ${assets
    .map((f) => `${f} (${kb(path.join(outDir, f))})`)
    .join(', ')}`,
);

#!/usr/bin/env node
// Compiles the world demo's wasm room server (site/worlddemo/web/server.dart)
// into site/public/worlddemo/ — same dart2wasm/dart2js pattern as
// scripts/build-demo.mjs. Runs as part of `npm run build`.
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
const demoDir = path.join(siteDir, 'worlddemo');
const outDir = path.join(siteDir, 'public', 'worlddemo');

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
    console.log('build-world-demo: dart not on PATH — keeping existing assets');
    process.exit(0);
  }
  console.error('build-world-demo: dart is not on PATH and no previous build exists');
  process.exit(1);
}

const kb = (p) => `${(statSync(p).size / 1024).toFixed(0)} KB`;
const run = (args) =>
  execFileSync('dart', args, { cwd: demoDir, stdio: 'inherit' });

rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });
run(['pub', 'get']);

// No dart2js fallback here: the fallback would need a different boot file
// and dart:html-free sources anyway; dart2wasm is the supported target.
run(['compile', 'wasm', 'web/server.dart', '-o', path.join(outDir, 'server.wasm')]);
copyFileSync(
  path.join(demoDir, 'web/boot.server.mjs'),
  path.join(outDir, 'boot.mjs'),
);
for (const f of readdirSync(outDir)) {
  if (f.endsWith('.map')) rmSync(path.join(outDir, f));
}
const assets = readdirSync(outDir).sort();
console.log(
  `build-world-demo: compiled with dart2wasm -> ${assets
    .map((f) => `${f} (${kb(path.join(outDir, f))})`)
    .join(', ')}`,
);

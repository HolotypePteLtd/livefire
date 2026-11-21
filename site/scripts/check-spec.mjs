#!/usr/bin/env node
// Cross-checks public/spec/rooms-protocol.json against the implementation:
//
//   1. The JSON must parse and be non-empty.
//   2. Every hub-handled frame in the spec must literally appear in
//      room_hub.dart (+ snapshot_codec.dart, which produces the
//      state/baseline/snapshot frames the hub sends).
//   3. Every frame-type literal in those sources must be documented in the
//      spec (both directions, no exceptions).
//   4. Authority-delegated frame types (documentedInstances) must appear in
//      the server_sdk authorities that implement them.
//
// Runs as part of `npm run build`; exits non-zero on any mismatch.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const siteDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repoDir = path.resolve(siteDir, '..');
const specPath = path.join(siteDir, 'public/spec/rooms-protocol.json');

const spec = JSON.parse(readFileSync(specPath, 'utf8'));
const problems = [];
const report = [];

if (!Array.isArray(spec.frames) || spec.frames.length === 0) {
  problems.push('spec.frames is missing or empty');
}

for (const frame of spec.frames ?? []) {
  for (const field of ['name', 'direction', 'handledBy', 'lane', 'when', 'fields']) {
    if (frame[field] === undefined) problems.push(`frame ${frame.name ?? '?'} lacks '${field}'`);
  }
}

// --- Extract every frame-type literal the hub + snapshot encoder handle. ---
const hubSources = [
  'packages/protocol/lib/src/room_hub.dart',
  'packages/protocol/lib/src/snapshot_codec.dart',
];
const hubText = hubSources
  .map((p) => readFileSync(path.join(repoDir, p), 'utf8'))
  .join('\n');

const found = new Set();
const patterns = [
  /\[\s*'type'\s*\]\s*(?:==|!=)\s*'(\w+)'/g, // msg['type'] == 'join'
  /\btype\s*(?:==|!=)\s*'(\w+)'/g, // type != 'chat'
  /'type'\s*:\s*'(\w+)'/g, // {'type': 'welcome', ...}
  /"type"\s*:\s*"(\w+)"/g, // '"type":"state",' / replaceFirst literals
];
for (const re of patterns) {
  for (const m of hubText.matchAll(re)) found.add(m[1]);
}
// 'packet' style accessors in snapshot_codec use the same ['type'] pattern.

const hubFrames = (spec.frames ?? [])
  .filter((f) => f.handledBy === 'hub')
  .map((f) => (f.name === 'command (game-defined)' ? null : f.name))
  .filter(Boolean);
const documented = new Set(hubFrames);

const undocumented = [...found].filter((t) => !documented.has(t));
const missing = hubFrames.filter((t) => !found.has(t));

report.push(`frame-type literals found in ${hubSources.join(' + ')}:`);
report.push(`  [${[...found].sort().join(', ')}]`);
report.push(
  `hub frames documented in the spec: [${[...new Set(hubFrames)].sort().join(', ')}]`,
);
if (undocumented.length) {
  problems.push(
    `in code but NOT documented: ${undocumented.join(', ')}`,
  );
}
if (missing.length) {
  problems.push(`documented but NOT in room_hub.dart: ${missing.join(', ')}`);
}

// --- Authority-delegated frames must exist in their implementations. ---
const authorityFiles = {
  publish: 'packages/server_sdk/lib/src/relay_authority.dart',
  publishRoom: 'packages/server_sdk/lib/src/relay_authority.dart',
  input: 'packages/server_sdk/lib/src/movement_authority.dart',
};
for (const frame of spec.frames ?? []) {
  for (const instance of frame.documentedInstances ?? []) {
    const type = instance.type?.split(' ')[0]; // e.g. "publish" from "publish ..."
    const file = authorityFiles[type];
    if (!file) {
      problems.push(`documentedInstance '${type}' has no known implementation file`);
      continue;
    }
    const src = readFileSync(path.join(repoDir, file), 'utf8');
    const hit = src.includes(`'${type}'`);
    report.push(
      `authority frame '${type}' -> ${file}: ${hit ? 'found' : 'MISSING'}`,
    );
    if (!hit) problems.push(`'${type}' not found in ${file}`);
  }
}

// --- Sanity: spec must carry the sources it claims. ---
for (const [key, rel] of Object.entries({
  hub: spec.sources?.hub,
  snapshots: spec.sources?.snapshots,
})) {
  if (!rel || !readFileSync(path.join(repoDir, rel), 'utf8')) {
    problems.push(`spec.sources.${key} does not resolve: ${rel}`);
  }
}
if ((spec.closeCodes ?? []).length === 0) problems.push('closeCodes is empty');

console.log(report.join('\n'));
if (problems.length) {
  console.error(`\ncheck-spec: FAILED\n  - ${problems.join('\n  - ')}`);
  process.exit(1);
}
console.log(
  `\ncheck-spec: OK — ${hubFrames.length} hub frames match the source both ways, ` +
    `${Object.keys(authorityFiles).length} authority frames verified, ` +
    `${spec.closeCodes.length} close codes documented.`,
);

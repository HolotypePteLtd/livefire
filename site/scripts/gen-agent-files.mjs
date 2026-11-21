#!/usr/bin/env node
// Generates the agent endpoints public/llms.txt and public/llms-full.txt
// from the same sources the site renders — no hand-copied drift. Run by
// `npm run build` (and standalone via `npm run gen`).
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const siteDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repoDir = path.resolve(siteDir, '..');
const docsDir = path.join(siteDir, 'src/content/docs/docs');
const read = (p) => readFileSync(p, 'utf8');

// Strip Starlight frontmatter and MDX plumbing so the output is plain
// markdown a text model can read directly.
function plainMarkdown(file, baseDir) {
  let text = read(path.join(baseDir, file));
  text = text.replace(/^---\n[\s\S]*?\n---\n/, '');
  text = text
    .split('\n')
    .filter((line) => !/^import\s/.test(line) && !/^<\/?\w+.*>\s*$/.test(line))
    .join('\n');
  return text.trim();
}

const llmsTxt = `# Livefire

> These docs are for humans too — start with Instant multiplayer server.
>
> Authoritative multiplayer rooms + realtime chat over an open wire protocol.
> Build clients in any language from the spec (rooms-protocol.json); an
> official SDK is available today. Use the hosted node in preview at
> https://play.holotype.com.sg (API key on request), run the server yourself
> (HTTP API + WebSockets), or embed the engine (RoomHub/RoomAuthority SDK).
> Private repo of Holotype Pte Ltd.

## Docs

- [Overview](/docs/): what Livefire gives you; the open-protocol story.
- [Instant multiplayer server](/docs/multiplayer-server/): the one-page path from zero to a running multiplayer backend — run the demo, wire the SDK into your game (RoomAuthority → RoomServer → RoomClient), chat and moderation, the hosted node in preview (play.holotype.com.sg, API key on request), put the rooms server online (Docker/Caddy), create rooms from a settings file via the HTTP API, connect players with join tokens (audience: non-engineers).
- [Shared state rooms](/docs/shared-state-rooms/): the relay template — settings-file reference (playerKeys/roomKeys quotas), publish/publishRoom commands, reading replicated state.
- [Physics rooms](/docs/physics-rooms/): the physics template — colliders/spawn/movement/inputMapping config, the input command, server-simulated poses, anti-cheat.
- [Player accounts](/docs/accounts/): Bluesky (AT Protocol) sign-in as a server setting — JWKS keygen, node.json auth block, the /auth/start button, DID-bound bans and profiles.
- [Identity ladder](/docs/identity-ladder/): day-0 anonymous play with device accounts (anon-<6>.<domain> on your PDS via admin-minted invite codes — ident.serviceKey is the PDS admin password; generated guest passwords persist for repo writes), client-held ES256 recovery keys, the encrypted keystore (passphrase-optional trade-off), /ident/* routes, the app-level trust note, upgrade paths.
- [Where accounts live](/docs/where-accounts-live/): the four options — Bluesky's public services (default), self-hosted Jetstream (planned), self-hosted PDS, self-hosted auth — for readers new to AT Protocol.
- [How it works](/docs/how-it-works/): plain-words explanation — your code sets the rules, the server runs them — plus the fine print; replaced Concepts (URL /docs/concepts/ redirects here).
- [Wire protocol](/docs/protocol/): every frame, its fields, direction and semantics; message table plus the repository protocol document.
- [Writing a client in any language](/docs/protocol-clients/): the minimum wire contract for a rooms client — connect, join, input and acks, snapshots, resume — without an SDK.
- [Room templates](/docs/templates/): relay and physics template JSON config reference (schemas, quotas, input protocol).
- [Rooms server HTTP API](/docs/api/): the API's endpoints, bearer auth, one-time join tokens, error shapes, server v0 implementation notes — with the hosted preview base URL (https://play.holotype.com.sg).
- [Developer panel](/docs/panel/): the node's built-in dashboard at /panel — Bluesky sign-in, admins, API keys created/shown-once/hashed with optional maxRooms/templates scopes, revocation, per-key counters, audit log, live rooms; SQLite or Supabase Postgres persistence for the platform half.
- [Self-hosting](/docs/self-hosting/): docker compose + Caddy TLS deployment, the Coolify/Traefik production pattern, node.json config reference, the two persistence modes (SQLite default; panel platform data in a shared Supabase Postgres via SUPABASE_URL + SUPABASE_SECRET_KEY), checklist.

## Machine-readable specs

- [rooms-protocol.json](/spec/rooms-protocol.json): the wire protocol as data — frames, fields, types, direction, required/optional, limits, close codes. Derived from room_hub.dart and cross-checked at build time.
- [room-authority.md](/spec/room-authority.md): the exact interface contract a game implements (RoomAuthority + RoomSocialAuthority) — every method, when the hub calls it, invariants.
- [llms-full.txt](/llms-full.txt): everything above as one plain-markdown file.

## Landing

- [Home](/): marketing site — hero, features, how it works, use cases, pricing (hosted node live in preview — API key on request; Hosted Pro still coming soon), FAQ.
`;

const sections = [
  {
    title: 'Overview',
    body: plainMarkdown('index.mdx', docsDir),
  },
  {
    title: 'Instant multiplayer server',
    body: plainMarkdown('multiplayer-server.md', docsDir),
  },
  {
    title: 'Shared state rooms',
    body: plainMarkdown('shared-state-rooms.md', docsDir),
  },
  {
    title: 'Physics rooms',
    body: plainMarkdown('physics-rooms.md', docsDir),
  },
  {
    title: 'Player accounts',
    body: plainMarkdown('accounts.md', docsDir),
  },
  {
    title: 'Identity ladder',
    body: plainMarkdown('identity-ladder.md', docsDir),
  },
  {
    title: 'Where accounts live',
    body: plainMarkdown('where-accounts-live.md', docsDir),
  },
  {
    title: 'How it works',
    body: plainMarkdown('how-it-works.md', docsDir),
  },
  {
    title: 'Identity (reference page)',
    body: plainMarkdown('identity.mdx', docsDir),
  },
  {
    title: 'Identity (repository document)',
    body: plainMarkdown('identity.md', path.join(repoDir, 'docs')),
  },
  {
    title: 'Wire protocol (reference page with frame table)',
    body: plainMarkdown('protocol.mdx', docsDir),
  },
  {
    title: 'Writing a client in any language',
    body: plainMarkdown('protocol-clients.mdx', docsDir),
  },
  {
    title: 'Wire protocol (repository document)',
    body: plainMarkdown('protocol.md', path.join(repoDir, 'docs')),
  },
  {
    title: 'Room templates (reference page)',
    body: plainMarkdown('templates.mdx', docsDir),
  },
  {
    title: 'Room templates (repository document)',
    body: plainMarkdown('room_templates.md', path.join(repoDir, 'docs')),
  },
  { title: 'Rooms server HTTP API (reference page)', body: plainMarkdown('api.mdx', docsDir) },
  {
    title: 'Rooms server HTTP API (repository document)',
    body: plainMarkdown('control_plane_api.md', path.join(repoDir, 'docs')),
  },
  { title: 'Developer panel', body: plainMarkdown('panel.md', docsDir) },
  { title: 'Self-hosting', body: plainMarkdown('self-hosting.md', docsDir) },
  {
    title: 'RoomAuthority interface contract (spec)',
    body: read(path.join(siteDir, 'public/spec/room-authority.md')),
  },
];

const header = `# Livefire — full documentation

> Single-file export of the Livefire docs site for text models.
> Source of truth: the Livefire repository (docs/, packages/, examples/).

## Contents

${sections.map((s, i) => `${i + 1}. ${s.title}`).join('\n')}
`;

const llmsFull =
  header +
  '\n---\n\n' +
  sections
    .map((s) => `# ${s.title}\n\n${s.body}\n\n---\n\n`)
    .join('')
    .trimEnd() +
  '\n';

writeFileSync(path.join(siteDir, 'public/llms.txt'), llmsTxt);
writeFileSync(path.join(siteDir, 'public/llms-full.txt'), llmsFull);
console.log(
  `gen-agent-files: wrote public/llms.txt (${llmsTxt.length} bytes), ` +
    `public/llms-full.txt (${llmsFull.length} bytes)`,
);

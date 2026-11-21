# Openfire site

Landing page + documentation site (Astro + Starlight, static build) with
machine-readable agent endpoints.

## Node versions

The build is verified on **Node 22, 24 and 26** (22.23.5, 24.19.0 and
26.13.1 at the time of verification; Node 26 is the current LTS).
`site/package.json` enforces `engines: >=22 <27` and pins the build-critical
toolchain (`astro`, `@astrojs/starlight`) to exact versions, so a fresh
`npm ci` resolves the same dependency set everywhere. `site/.nvmrc` (24) is
the canonical version for local development, Volta and CI.

Always install with **`npm ci`** (or `npm install` with the committed
`package-lock.json` present) — never `npm update`. If a build fails with a
SyntaxError such as astro-expressive-code's `Failed to load syntax
highlighter ... Invalid or unexpected token`, the dependency tree on that
machine is stale or corrupted (shiki grammar bundles fail to parse when
truncated by an interrupted install or a bad npm cache): remove
`node_modules`, optionally `npm cache clean --force`, then `npm ci` again.
npm on Node 26+ may also print `install-scripts` warnings for nested
esbuild copies (wrangler's); the site build does not depend on those
postinstall scripts.

## Build & verify

```sh
npm ci
npm run build
```

`npm run build` runs three steps:

1. `scripts/gen-agent-files.mjs` — generates `public/llms.txt` and
   `public/llms-full.txt` **from the same sources the site renders** (the
   Starlight pages plus the repository documents they embed), so they cannot
   drift.
2. `scripts/check-spec.mjs` — cross-checks `public/spec/rooms-protocol.json`
   against the implementation: every hub frame documented in the spec must
   literally appear in `packages/protocol/lib/src/room_hub.dart` (plus
   `snapshot_codec.dart`, which produces the `state`/`baseline`/`snapshot`
   frames) and vice versa; authority-delegated frames (`publish`,
   `publishRoom`, `input`) are verified against their implementations in
   `server_sdk`. The build fails on any mismatch.
3. `astro build` — emits static files to `dist/`.

The wire-protocol spec itself is hand-curated from reading the source (see
its `sources` map); the script keeps it honest.

## Layout

| Path | Source |
| --- | --- |
| `/` landing (`src/pages/index.astro`) | marketing site: hero, features, how it works, use cases, pricing, FAQ |
| `/demo/` | live in-page demo: the counter room engine (site/demo, compiled by `scripts/build-demo.mjs` to `public/demo/` at build time — needs the Dart SDK on PATH) and embedded on `/docs/multiplayer-server/` via a lazy iframe |
| `/world/server/`, `/world/client/` | the world demo's frames: wasm room server (site/worlddemo, compiled by `scripts/build-world-demo.mjs` to `public/worlddemo/`) and the three.js clients (three vendored via npm); orchestrated onto `/docs/multiplayer-server/` by `public/world/orchestrator.js` on click |
| `/docs/` Overview | distilled |
| `/docs/multiplayer-server/` | README.md quickstart + examples/counter + the former chat / put-my-game-online recipes |
| `/docs/shared-state-rooms/` | docs/room_templates.md (relay), distilled |
| `/docs/physics-rooms/` | docs/room_templates.md (physics), distilled |
| `/docs/accounts/` | docs/identity.md (server config parts), distilled |
| `/docs/where-accounts-live/` | new: where accounts live (Bluesky default / self-hosted Jetstream / PDS / auth), fact-checked against `packages/atproto_identity` + `packages/node/lib/src/node_config.dart` |
| `/docs/how-it-works/` | docs/protocol.md, distilled (URL /docs/concepts/ redirects here) |
| `/docs/protocol/` | message table derived from `room_hub.dart` + `docs/protocol.md` embedded via markdown import |
| `/docs/templates/` | `docs/room_templates.md` embedded via markdown import |
| `/docs/api/` | `docs/control_plane_api.md` embedded via markdown import |
| `/docs/panel/` | new: the developer panel (`/panel`) — Bluesky sign-in, adminDids, key lifecycle |
| `/docs/self-hosting/` | `docker-compose.yml`, `deploy/Caddyfile`, `deploy/node.example.json`, plus the Coolify and Traefik example from `deploy/coolify/` |
| `/llms.txt`, `/llms-full.txt` | generated at build time |
| `/spec/rooms-protocol.json` | curated from `packages/protocol` sources, cross-checked at build time |
| `/spec/room-authority.md` | curated from `room_authority.dart` + `room_hub.dart` call sites |

Pages that mirror repository documents embed them with Astro markdown
imports (no copies); pages that distill note their source at the bottom.

## Deploying to Cloudflare Pages (alternative to the compose/Caddy path)

The site is plain static output, so besides the compose/Caddy service
below it can be deployed to Cloudflare Pages with the node API on a
separate host.

- `wrangler.toml` configures the Pages project (`rooms-sdk-docs`, output
  `dist/`, **Pages not Workers static assets** — the choice and its
  reasoning are documented in that file's comments). It contains no
  secrets; the token lives in `CLOUDFLARE_API_TOKEN` (plus
  `CLOUDFLARE_ACCOUNT_ID` in CI).
- `wrangler` is pinned as a devDependency, and `npm run deploy:cloudflare`
  builds then deploys in one step.

### Path A — direct upload (wrangler)

```sh
cd site
export CLOUDFLARE_API_TOKEN=<pages:edit token>   # from dash.cloudflare.com → My Profile → API Tokens
npm ci
npm run deploy:cloudflare
# equivalent long form:
#   npm run build && npx wrangler pages deploy
```

The first run creates the `rooms-sdk-docs` Pages project (the name comes
from `wrangler.toml`); if wrangler asks for the production branch, accept
the default (`master`). Subsequent runs upload a new deployment of the
same project. `--commit-dirty=true` only stops the local
uncommitted-changes prompt; CI deploys are clean.

### Path B — git-integrated (dashboard)

In the Cloudflare dashboard: Workers & Pages → Create → Pages → *Connect
to Git*. Grant the Cloudflare GitHub App access to the repository.
Build settings:

| Setting | Value |
| --- | --- |
| Root directory | `site` |
| Build command | `npm run build` |
| Build output directory | `dist` |
| Node version | 24 |

The build runs in the `site/` root directory but still needs the rest of
the checkout — the docs pages markdown-import `docs/*.md` and the
build-time spec check reads `packages/...`. Git-integrated builds check
out the whole repository, so this works as-is.

### Path C — GitHub Actions (optional, pre-wired)

Set `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` as repository
secrets, set your Pages project name in `wrangler.toml`, and manually
run the **Deploy docs to Cloudflare Pages** workflow.

### Two origins, no surprises

The docs and agent endpoints (`llms.txt`, `llms-full.txt`, `/spec/*`) are
same-origin with whatever domain serves them. For a separate node origin,
set the node's `publicBaseUrl` to the external API origin and include the docs origin in its WebSocket
origin allowlist.

## Serving (docker compose)

The site is wired into `docker-compose.yml` as a **one-shot init
container**:

- `site` builds `dist/` in a Node 24 build stage with Dart and copies it into the
  shared `rooms-site` volume, then exits (`restart: "no"`).
- `caddy` mounts `rooms-site:/srv/site:ro` and serves it with `file_server`
  for every path that is not `/v1/*` or `/play/*` (those are proxied to
  `rooms-node:8787`), gated by
  `depends_on: site: condition: service_completed_successfully` so Caddy
  never starts before the files exist.

The build context is the **repository root** (not `site/`) because the docs
pages markdown-import `../docs/*.md` and the build-time spec check reads
`../packages/...`. Since the root `.dockerignore` excludes `docs/` for the
node image, this Dockerfile uses its own `site/Dockerfile.dockerignore`
(BuildKit per-Dockerfile ignore files).

The GitHub links on the landing page point at
`https://github.com/HolotypePteLtd/openfire` — adjust if the repository
moves.

## Editing

- Docs pages: `src/content/docs/docs/*.md(x)` (the nested `docs/` directory
  is what puts them under `/docs/…`).
- Landing: `src/pages/index.astro` + `src/styles/landing.css`.
- Agent specs: `public/spec/*` (committed; validated at build time).
- Docs config: `astro.config.mjs`.

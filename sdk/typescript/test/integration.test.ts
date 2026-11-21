/**
 * Cross-language integration tests — the point of the SDK: REAL rooms
 * servers driven by THIS TypeScript client.
 *
 * 1. A Dart `RoomServer` (the counter example authority,
 *    examples/counter/bin/serve.dart): join handshake, roster, chat
 *    round-trip, commands mutating authority state and replicating as
 *    deltas, resume with the same player id after a forced connection
 *    drop, and clean leave. The server is spawned here and exits when
 *    its stdin closes.
 *
 * 2. The full rooms node (packages/node — the same node software the
 *    hosted service runs), driven the hosted way: create a room and mint
 *    join tokens over the HTTP API, join with the SDK passing the
 *    one-time joinToken (it travels as `?token=` on the /play URL and
 *    is validated before the WebSocket upgrade), chat, publish, watch
 *    the delta replicate — and watch a bogus token get rejected.
 *
 * 3. The admin namespace against the same node, with the panel enabled:
 *    createRoom defaults, mintToken, join by url (both token styles),
 *    listRooms, deleteRoom, the /panel page, and a panel-issued key
 *    working until it is revoked (then 401).
 */
import { test } from 'node:test';
import assert from 'node:assert';
import { spawn } from 'node:child_process';
import http from 'node:http';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { createHmac, randomBytes } from 'node:crypto';
import path from 'node:path';

import { Openfire } from '../src/index.ts';
import type { Room, RoomEvent } from '../src/index.ts';
import {
  deviceAccount,
  generateRecoveryKeyPair,
  memoryStorage,
  openKeystore,
} from '../src/index.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const counterDir = path.resolve(here, '../../../examples/counter');
const nodeDir = path.resolve(here, '../../../packages/node');
const PORT = 18791;
const NODE_PORT = 18792;
const API_KEY = 'sk_ts_sdk_integration';
const NODE_SECRET = 'integration-test-node-secret-32-chars';
const ADMIN_DID = 'did:plc:ts-sdk-test-admin';

interface Server {
  uri: string;
  stop(): Promise<void>;
}

async function startServer(): Promise<Server> {
  const child = spawn('dart', ['run', 'bin/serve.dart', String(PORT)], {
    cwd: counterDir,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const chunks: Buffer[] = [];
  let text = '';
  const uri = new Promise<string>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error('server did not start: ' + text)),
      60_000,
    );
    child.stdout!.on('data', (chunk: string | Buffer) => {
      text += chunk.toString();
      const match = text.match(/ws:\/\/\S+/);
      if (match && timer !== null) {
        clearTimeout(timer);
        resolve(match[0]);
      }
    });
    child.once('exit', () => {
      if (!text.match(/ws:\/\//)) reject(new Error('server exited: ' + text));
    });
  });
  await uri;
  return {
    uri: await uri,
    stop: () =>
      new Promise((resolve) => {
        child.once('exit', () => resolve());
        child.stdin!.end(); // graceful shutdown, no signals
      }),
  };
}

function waitFor(
  what: string,
  check: () => boolean,
  timeoutMs = 8000,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const tick = () => {
      if (check()) {
        resolve();
        return;
      }
      if (Date.now() - started > timeoutMs) {
        reject(new Error('timed out waiting for ' + what));
        return;
      }
      setTimeout(tick, 25);
    };
    tick();
  });
}

function count(state: Room['state'], id: string): number {
  const players = (state?.['players'] ?? {}) as Record<
    string,
    { count?: number }
  >;
  return players[id]?.count ?? -1;
}

/** Runs a command to completion (used for the JWKS generator tool). */
function run(
  command: string,
  args: readonly string[],
  cwd: string,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    child.stderr?.on('data', (chunk: string | Buffer) => {
      err += chunk.toString();
    });
    child.once('exit', (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} exited ${code}: ${err}`)),
    );
  });
}

/**
 * Mints a panel session (`ps_`) under the node secret this test owns —
 * the same construction the node uses (HMAC-SHA256 over `ps_` + the
 * base64url payload; Dart base64url keeps `=` padding).
 */
function mintPanelSession(did: string): string {
  const payload = JSON.stringify({
    did,
    exp: Date.now() + 12 * 3600_000,
    jti: randomBytes(12).toString('base64url'),
  });
  let body = Buffer.from(payload, 'utf8').toString('base64url');
  while (body.length % 4 !== 0) body += '=';
  const mac = createHmac('sha256', Buffer.from(NODE_SECRET, 'utf8'))
    .update(`ps_${body}`)
    .digest('hex');
  return `ps_${body}.${mac}`;
}

/** One panel API call with an admin session. */
async function panelApi(
  method: string,
  requestPath: string,
  body?: unknown,
): Promise<{ status: number; json: any }> {
  const response = await fetch(`http://127.0.0.1:${NODE_PORT}${requestPath}`, {
    method,
    headers: {
      Authorization: `Bearer ${mintPanelSession(ADMIN_DID)}`,
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, json: text === '' ? {} : JSON.parse(text) };
}

/** The PDS admin password the node's ident.serviceKey carries. */
const PDS_ADMIN_PASSWORD = 'ts-fixture-admin-pw';

/** A fake STOCK reference PDS: POST /xrpc/com.atproto.server.
 * createInviteCode needs basic auth admin:<password> ({"useCount":1}
 * -> a single-use {"code"}), and createAccount needs
 * {handle, password, inviteCode} — exactly the live-confirmed contract
 * the node's HttpGuestAccountHost implements. Unique handles (409). */
function startFakePds(): Promise<{
  uri: string;
  stop(): Promise<void>;
  created: { handle: string; password: string }[];
  inviteMints: number;
}> {
  const created: { handle: string; password: string }[] = [];
  const handles = new Set<string>();
  const inviteCodes = new Set<string>();
  const state = { inviteMints: 0 };
  const server = http.createServer(
    (request: http.IncomingMessage, response: http.ServerResponse) => {
    let body = '';
    request.on('data', (chunk: Buffer | string) => (body += chunk.toString()));
    request.on('end', () => {
      if (request.method !== 'POST') {
        response.writeHead(404);
        response.end();
        return;
      }
      if (request.url === '/xrpc/com.atproto.server.createInviteCode') {
        const auth = (request.headers['authorization'] ?? '') as string;
        const expected = 'Basic ' + Buffer
          .from(`admin:${PDS_ADMIN_PASSWORD}`, 'utf8')
          .toString('base64');
        if (auth !== expected) {
          response.writeHead(401, { 'Content-Type': 'application/json' });
          response.end(JSON.stringify({ error: 'AuthenticationRequired' }));
          return;
        }
        const code = `invite-${state.inviteMints++}`;
        inviteCodes.add(code);
        response.writeHead(200, { 'Content-Type': 'application/json' });
        response.end(JSON.stringify({ code }));
        return;
      }
      if (request.url !== '/xrpc/com.atproto.server.createAccount') {
        response.writeHead(404);
        response.end();
        return;
      }
      const parsed = JSON.parse(body) as {
        handle: string;
        password: string;
        inviteCode: string;
      };
      if (!inviteCodes.delete(parsed.inviteCode ?? '')) {
        response.writeHead(400, { 'Content-Type': 'application/json' });
        response.end(JSON.stringify({
          error: 'InvalidInviteCode',
          message: 'No invite code provided',
        }));
        return;
      }
      if (
        !parsed.handle.endsWith('.guest.test') ||
        handles.has(parsed.handle) ||
        (parsed.password ?? '').length < 24
      ) {
        response.writeHead(409, { 'Content-Type': 'application/json' });
        response.end(JSON.stringify({
          error: 'InvalidRequestError',
          message: 'Handle already taken',
        }));
        return;
      }
      handles.add(parsed.handle);
      created.push({ handle: parsed.handle, password: parsed.password });
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify({
        did: `did:plc:device${handles.size}`,
        handle: parsed.handle,
      }));
    });
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const address = server.address() as { port: number };
      resolve({
        uri: `http://127.0.0.1:${address.port}`,
        stop: () =>
          new Promise((done) => server.close(() => done())),
        created,
        get inviteMints() {
          return state.inviteMints;
        },
      });
    });
  });
}

/** Spawns the real rooms node (packages/node) with the panel enabled:
 * guest rooms plus a panel admin DID (atproto wired so the panel is
 * 'enabled'; no real entryway is ever contacted — this test owns the node
 * secret and mints its panel session directly, like the operator would).
 * No origin allowlist (empty allows every origin). The first run compiles
 * the native physics bridge, so startup is given minutes. */
async function startNode(options: {
  ident?: { pdsUrl: string; serviceKey: string; handleDomain: string };
} = {}): Promise<Server> {
  const dataDir = mkdtempSync(path.join(tmpdir(), 'rooms-node-'));
  const configPath = path.join(dataDir, 'node.json');
  const jwksPath = path.join(dataDir, 'oauth-client-jwks.json');
  // The node's OAuth client key (only its public half is ever served).
  await run('dart', ['run', 'tool/gen_client_jwks.dart', jwksPath], nodeDir);
  writeFileSync(
    configPath,
    JSON.stringify({
      publicBaseUrl: `http://127.0.0.1:${NODE_PORT}`,
      nodeSecret: NODE_SECRET,
      apiKeys: { default: API_KEY },
      dataDir,
      listen: { port: NODE_PORT, address: '127.0.0.1' },
      joinTokenTtlSeconds: 900,
      physics: false,
      adminDids: [ADMIN_DID],
      auth: {
        providers: ['guest', 'atproto'],
        atproto: {
          clientName: 'ts sdk test node',
          entrywayUrl: 'https://entryway.invalid',
          plcDirectoryUrl: 'https://plc.invalid',
          jwksPath,
        },
      },
      ...(options.ident === undefined
        ? {}
        : {
            ident: {
              pdsUrl: options.ident.pdsUrl,
              serviceKey: options.ident.serviceKey,
              handleDomain: options.ident.handleDomain,
            },
          }),
    }),
  );
  const child = spawn(
    'dart',
    ['run', 'bin/node.dart', '--config', configPath],
    { cwd: nodeDir, stdio: ['pipe', 'pipe', 'pipe'] },
  );
  let text = '';
  const ready = new Promise<void>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error('node did not start: ' + text)),
      300_000,
    );
    child.stdout!.on('data', (chunk: string | Buffer) => {
      text += chunk.toString();
      if (text.includes('rooms-node listening on') && timer !== null) {
        clearTimeout(timer);
        resolve();
      }
    });
    child.stderr!.on('data', (chunk: string | Buffer) => {
      text += chunk.toString();
    });
    child.once('exit', () => {
      if (!text.includes('rooms-node listening on')) {
        reject(new Error('node exited: ' + text));
      }
    });
  });
  await ready;
  return {
    uri: `http://127.0.0.1:${NODE_PORT}`,
    stop: () =>
      new Promise((resolve) => {
        child.once('exit', () => {
          rmSync(dataDir, { recursive: true, force: true });
          resolve();
        });
        child.stdin!.end();
        // Unlike examples/counter's serve.dart, the node does not watch
        // stdin; its documented shutdown path is SIGTERM (drain rooms).
        child.kill('SIGTERM');
      }),
  };
}

/** One control-plane call (the hosted flow): Bearer key, JSON body. */
async function api(
  method: string,
  requestPath: string,
  body?: unknown,
): Promise<Record<string, any>> {
  const response = await fetch(`http://127.0.0.1:${NODE_PORT}${requestPath}`, {
    method,
    headers: {
      Authorization: `Bearer ${API_KEY}`,
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`${method} ${requestPath} -> ${response.status}: ${text}`);
  }
  return text === '' ? {} : (JSON.parse(text) as Record<string, any>);
}

test('join, chat, command, snapshot and resume against the real server', async () => {
  const server = await startServer();
  try {
    // ---- Join: handshake + welcome + initial snapshot ----------------
    const sam = await Openfire.join({
      host: `http://127.0.0.1:${PORT}`,
      roomKey: 'demo-room',
      name: 'Sam',
    });
    assert.equal(sam.playerId, 'p1');
    assert.equal(sam.capacity, 8);
    assert.ok(sam.state, 'initial snapshot applied at join');
    assert.equal(count(sam.state, 'p1'), 0);
    assert.ok(sam.resumeToken, 'resume token received');

    const ada = await Openfire.join({
      host: `http://127.0.0.1:${PORT}`,
      roomKey: 'demo-room',
      name: 'Ada',
    });
    assert.equal(ada.playerId, 'p2');
    await waitFor('both rosters at two members', () =>
      sam.roster.members.length === 2 && ada.roster.members.length === 2,
    );

    // ---- Chat round-trip ---------------------------------------------
    const chatFromSam = new Promise((resolve) =>
      ada.chat.on(function onChat(message) {
        if (message.playerName === 'Sam' && message.text === 'hello!') {
          resolve(message);
        }
      }),
    );
    sam.chat.send('hello!');
    const chat = (await chatFromSam) as { playerId: string; text: string };
    assert.equal(chat.playerId, 'p1');
    assert.equal(chat.text, 'hello!');

    // ---- Commands mutate authority state; snapshots replicate --------
    for (let i = 0; i < 3; i++) {
      sam.command({ type: 'increment' });
    }
    await waitFor("Ada sees Sam's count at 3", () => count(ada.state, 'p1') === 3);
    await waitFor("Sam sees his own count at 3", () => count(sam.state, 'p1') === 3);

    // ---- Resume: forced drop, same id restored, state continues ------
    const events: RoomEvent[] = [];
    ada.onEvent((e) => events.push(e));
    const reconnected = new Promise((resolve) =>
      ada.onEvent(function onEvent(e) {
        if (e.kind === 'reconnected') {
          resolve(e);
        }
      }),
    );
    ada.dropConnection(); // like wifi going away: no leave frame
    const again = (await reconnected) as { id: string };
    assert.equal(again.id, 'p2', 'same player id after resume');
    assert.ok(
      events.some((e) => e.kind === 'reconnecting'),
      'reconnecting event fired',
    );

    // While Ada was down, Sam kept playing; Ada catches up on rejoin.
    for (let i = 0; i < 2; i++) {
      sam.command({ type: 'increment' });
    }
    await waitFor('Ada catches up to 5 after resume', () => count(ada.state, 'p1') === 5);
    await waitFor('roster restored with both players', () =>
      ada.roster.members.length === 2 &&
      ada.roster.members.some((m) => m.id === 'p2' && m.connected),
    );
    assert.ok(
      ada.chatHistory.some((m) => m.text === 'hello!'),
      'chat history replayed on resume',
    );

    // ---- Clean leave ---------------------------------------------------
    await sam.close();
    await ada.close();
    await waitFor('Ada sees Sam gone after leave', () =>
      ada.roster.members.every((m) => m.id !== 'p1'),
    );
  } finally {
    await server.stop();
  }
});

test('hosted shape: API-created room, joinToken in the URL, chat and deltas', async () => {
  const server = await startNode();

  try {
    // ---- Create a room over the control plane (exactly the hosted flow).
    // Same relay config as the docs walkthrough.
    const room = await api('POST', '/v1/rooms', {
      template: 'relay',
      config: {
        version: 1,
        template: 'relay',
        capacity: 16,
        chat: true,
        maxRows: 64,
        totalBytes: 32768,
        playerKeys: {
          pose: { maxBytes: 256, publishesPerSecond: 10 },
        },
        roomKeys: {
          phase: { maxBytes: 64, publishesPerSecond: 1 },
        },
      },
    });
    assert.match(room['roomId'] as string, /^rm_/);
    assert.ok((room['roomKey'] as string).length > 0);
    assert.equal(
      room['url'],
      `ws://127.0.0.1:${NODE_PORT}/play/${room['roomKey']}`,
    );
    assert.match(room['joinToken'] as string, /^jt_/);
    assert.ok(room['joinTokenExpiresAt'], 'join token expiry present');
    assert.match(room['creatorToken'] as string, /^ct_/);

    // ---- Join with the SDK: the one-time token rides the URL (?token=).
    const sam = await Openfire.join({
      host: `http://127.0.0.1:${NODE_PORT}`,
      roomKey: room['roomKey'] as string,
      joinToken: room['joinToken'] as string,
      name: 'Sam',
    });
    assert.equal(sam.playerId, 'p1');
    assert.ok(sam.state, 'initial snapshot applied at join');
    assert.ok(sam.resumeToken, 'resume token received');

    // Tokens are one-time: the second player needs a fresh one, minted
    // by roomId over the API.
    const minted = await api('POST', `/v1/rooms/${room['roomId']}/tokens`, {});
    assert.match(minted['joinToken'] as string, /^jt_/);
    const ada = await Openfire.join({
      host: `http://127.0.0.1:${NODE_PORT}`,
      roomKey: room['roomKey'] as string,
      joinToken: minted['joinToken'] as string,
      name: 'Ada',
    });
    assert.equal(ada.playerId, 'p2');
    await waitFor('both rosters at two members', () =>
      sam.roster.members.length === 2 && ada.roster.members.length === 2,
    );

    // ---- Chat round-trip through the token-gated room ------------------
    const chatFromSam = new Promise((resolve) =>
      ada.chat.on(function onChat(message) {
        if (message.playerName === 'Sam' && message.text === 'hello!') {
          resolve(message);
        }
      }),
    );
    sam.chat.send('hello!');
    const chat = (await chatFromSam) as { playerId: string; text: string };
    assert.equal(chat.playerId, 'p1');
    assert.equal(chat.text, 'hello!');

    // ---- Publish and replicate (relay template) ------------------------
    sam.command({
      type: 'publish',
      key: 'pose',
      value: { x: 1.25, y: 0, z: -3.5 },
    });
    await waitFor("Ada sees Sam's pose at x=1.25", () => {
      const players = (ada.state?.['players'] ?? {}) as Record<
        string,
        Record<string, { x?: number }>
      >;
      return players['p1']?.['pose']?.['x'] === 1.25;
    });

    // ---- The gate is real: a bogus token never upgrades ----------------
    await assert.rejects(() =>
      Openfire.join({
        host: `http://127.0.0.1:${NODE_PORT}`,
        roomKey: room['roomKey'] as string,
        joinToken: 'jt_bogus.deadbeef',
        name: 'Mallory',
      }),
    );

    await sam.close();
    await ada.close();
  } finally {
    await server.stop();
  }
});

test('admin namespace: create, mint, join by url, list, delete, revocation', async () => {
  const server = await startNode();

  try {
    // The documented minimal integration, backend edition.
    const of = Openfire.admin(API_KEY, `http://127.0.0.1:${NODE_PORT}`);
    const room = await of.createRoom({ template: 'relay', capacity: 16 });
    assert.match(room.roomId, /^rm_/);
    assert.match(room.joinToken, /^jt_/);
    assert.equal(
      room.url,
      `ws://127.0.0.1:${NODE_PORT}/play/${room.roomKey}`,
    );

    // Panel smoke: the page is served; the API refuses anonymous access.
    const page = await fetch(`http://127.0.0.1:${NODE_PORT}/panel`);
    assert.equal(page.status, 200);
    assert.match(page.headers.get('content-security-policy') ?? '', /self/);
    const anonKeys = await fetch(`http://127.0.0.1:${NODE_PORT}/panel/api/keys`);
    assert.equal(anonKeys.status, 401);

    // Panel-issued key lifecycle: create -> works -> revoke -> 401.
    const createdKey = await panelApi('POST', '/panel/api/keys', {
      label: 'admin namespace test',
    });
    assert.equal(createdKey.status, 201);
    const panelKey = createdKey.json.key as string;
    assert.match(panelKey, /^sk_/);
    const withPanelKey = Openfire.admin(
      panelKey,
      `http://127.0.0.1:${NODE_PORT}`,
    );
    const panelRoom = await withPanelKey.createRoom({
      template: 'relay',
      capacity: 8,
    });
    assert.match(panelRoom.roomId, /^rm_/);

    // Scope fields (and any future control-plane body addition) ride
    // along verbatim via `extra`; the node ignores unknown fields, so
    // this still creates a room.
    const passthroughRoom = await withPanelKey.createRoom({
      template: 'relay',
      capacity: 4,
      extra: { maxRooms: 2, templates: ['relay'] },
    });
    assert.match(passthroughRoom.roomId, /^rm_/);

    // Mint for a second player and join by url — the client edition.
    const { joinToken } = await of.mintToken(room, 'Ada');
    assert.match(joinToken, /^jt_/);
    const sam = await Openfire.join({
      url: room.url,
      joinToken: room.joinToken,
      name: 'Sam',
    });
    const ada = await Openfire.join({
      url: `${room.url}?token=${joinToken}`, // token carried by the url
      name: 'Ada',
    });
    assert.equal(sam.playerId, 'p1');
    assert.equal(ada.playerId, 'p2');
    await waitFor('both rosters at two members', () =>
      sam.roster.members.length === 2 && ada.roster.members.length === 2,
    );

    // listRooms sees both rooms; deleteRoom drains one (deleted rooms
    // stay listed with status closed — the v0 list is unfiltered).
    const listing = await of.listRooms();
    assert.ok(listing.rooms.some((r) => r.roomId === room.roomId));
    assert.ok(listing.rooms.some((r) => r.roomId === panelRoom.roomId));
    await of.deleteRoom(panelRoom.roomId);
    const after = await of.listRooms();
    const drained = after.rooms.find((r) => r.roomId === panelRoom.roomId);
    assert.ok(drained === undefined || drained.status === 'closed');

    // Revoked key failing 401: revoke through the panel, then use it.
    const revoked = await panelApi(
      'POST',
      `/panel/api/keys/${createdKey.json.id}/revoke`,
    );
    assert.equal(revoked.status, 200);
    await assert.rejects(
      () =>
        withPanelKey.createRoom({
          template: 'relay',
          config: { version: 1, template: 'relay' },
        }),
      /401/,
    );

    // Per-key counters moved on the panel side (both rooms the panel
    // key created — including the passthrough one).
    const keys = await panelApi('GET', '/panel/api/keys');
    const row = keys.json.keys.find((k: { label: string }) =>
      k.label === 'admin namespace test'
    );
    assert.equal(row.roomsCreated, 2);

    await sam.close();
    await ada.close();
  } finally {
    await server.stop();
  }
});

test('device accounts: create, play, lose state, recover same did; wrong key fails', async () => {
  const pds = await startFakePds();
  const server = await startNode({
    ident: {
      pdsUrl: pds.uri,
      serviceKey: PDS_ADMIN_PASSWORD,
      handleDomain: 'guest.test',
    },
  });

  try {
    // ---- Create: a room from the control plane, then the account -----
    const room = await api('POST', '/v1/rooms', {
      template: 'relay',
      config: {
        version: 1,
        template: 'relay',
        capacity: 16,
        chat: true,
        maxRows: 64,
        totalBytes: 32768,
        playerKeys: {
          pose: { maxBytes: 256, publishesPerSecond: 10 },
        },
        roomKeys: {
          phase: { maxBytes: 64, publishesPerSecond: 1 },
        },
      },
    });
    const storage = memoryStorage();
    const account = await deviceAccount.create({
      host: `http://127.0.0.1:${NODE_PORT}`,
      roomKey: room['roomKey'] as string,
      keystore: openKeystore({ storage }),
    });
    assert.match(account.did, /^did:plc:device\d+$/);
    assert.match(account.handle, /^anon-[a-z2-9]{6}\.guest\.test$/);
    assert.match(account.session, /^gs_/);
    // The stock-PDS contract was followed end to end: one admin-minted
    // single-use invite code, createAccount with handle + a generated
    // 24+-char password, no e-mail.
    assert.equal(pds.inviteMints, 1);
    assert.deepEqual(pds.created.map((c) => c.handle), [account.handle]);
    assert.ok(pds.created[0]!.password.length >= 24);

    // ---- Play: same Room surface as join() ----------------------------
    const game = await account.joinRoom({
      roomKey: room['roomKey'] as string,
      name: 'Sam',
    });
    assert.equal(game.playerId, 'p1');
    game.command({
      type: 'publish',
      key: 'pose',
      value: { x: 2.5, y: 0, z: -1 },
    });
    await waitFor('the published pose is in the state', () => {
      const players = (game.state?.['players'] ?? {}) as Record<
        string,
        Record<string, { x?: number }>
      >;
      return players['p1']?.['pose']?.['x'] === 2.5;
    });
    await game.close();
    // The hub releases p1's slot asynchronously after the leave frame;
    // let it settle so the rejoined account gets its slot back rather
    // than a fresh one.
    await new Promise((resolve) => setTimeout(resolve, 250));

    // ---- Lose ALL client state except the keystore --------------------
    // (new device: session cache gone, key material — encrypted — kept)
    const carriedOver = memoryStorage();
    const saved = await storage.get('device-account');
    assert.ok(saved, 'the keystore persisted an encrypted record');
    await carriedOver.set('device-account', saved!);
    const entry = await openKeystore({ storage: carriedOver }).load();
    assert.ok(entry?.session, 'pre-loss entry cached a session');

    // ---- Recover: same did, fresh session, play again ------------------
    const recovered = await deviceAccount.recover({
      host: `http://127.0.0.1:${NODE_PORT}`,
      keystore: openKeystore({ storage: carriedOver }),
      roomKey: room['roomKey'] as string,
    });
    assert.equal(recovered.did, account.did, 'same did after recovery');
    assert.match(recovered.session, /^gs_/);
    assert.notEqual(recovered.session, entry!.session!.token);
    const secondRun = await recovered.joinRoom({
      roomKey: room['roomKey'] as string,
      name: 'Sam',
    });
    // Player ids are positional and never reused after a clean leave
    // (the hub's counter is monotonic) — the identity that matters is
    // the did, which recovery preserved.
    assert.match(secondRun.playerId, /^p\d+$/);
    secondRun.command({
      type: 'publish',
      key: 'pose',
      value: { x: -3, y: 0, z: 0 },
    });
    const recoveredId = secondRun.playerId;
    await waitFor('the recovered account can publish', () => {
      const players = (secondRun.state?.['players'] ?? {}) as Record<
        string,
        Record<string, { x?: number }>
      >;
      return players[recoveredId]?.['pose']?.['x'] === -3;
    });
    await secondRun.close();

    // ---- A different recovery key cannot prove control ------------------
    const thiefStorage = memoryStorage();
    const pair = await generateRecoveryKeyPair();
    await openKeystore({ storage: thiefStorage }).save({
      did: account.did, // claims the victim's did...
      handle: account.handle,
      publicJwk: pair.publicJwk,
      privateJwk: pair.privateJwk, // ...but holds the wrong key
      createdAt: new Date().toISOString(),
    });
    await assert.rejects(
      () =>
        deviceAccount.recover({
          host: `http://127.0.0.1:${NODE_PORT}`,
          keystore: openKeystore({ storage: thiefStorage }),
        }),
      /recovery failed \(403\)/,
    );
  } finally {
    await server.stop();
    await pds.stop();
  }
});

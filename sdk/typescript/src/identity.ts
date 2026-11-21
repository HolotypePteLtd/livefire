/**
 * The guest identity ladder for game clients
 * (node docs: `docs/identity.md` → guest identity ladder; site docs:
 * "Identity ladder").
 *
 * Day 0: the CLIENT generates an ES256 keypair. The private key never
 * leaves the client — it lives encrypted in local storage (IndexedDB in
 * browsers; the same keystore works over any injected storage in Node).
 * Only the PUBLIC half travels to the node:
 *
 *   POST /ident/device-account {rotationPubJwk} -> {did, handle, session}
 *
 * When the session is lost (new device, cleared storage) the client
 * proves DID control by signing a server-issued single-use nonce with
 * the recovery key:
 *
 *   GET  /ident/nonce?did=…
 *   POST /ident/recover {did, nonce, assertion}
 *
 * and gets a fresh session for the SAME did. The play surface is the
 * usual one: create/recover accept a `room` and return a one-time join
 * token for it, so `joinRoom()` hands back the same `Room` as
 * `Openfire.join()`.
 *
 * TRUST NOTE (verbatim from the docs): the node operator holds the
 * PDS-level rotation key and therefore outranks the client recovery
 * key at the PDS layer — v1 guarantees are app-level (recovery from
 * session loss), not protection against a malicious operator. Same
 * trust level as Bluesky itself today.
 */

import { Room } from './room.ts';
import type { RoomOptions } from './room.ts';

/** An EC P-256 keypair in JWK form (ES256). */
export interface RecoveryKeyPair {
  publicJwk: JsonWebKey;
  privateJwk: JsonWebKey;
}

/** What the keystore persists (encrypted) for one device account. */
export interface KeystoreEntry {
  did: string;
  handle: string;
  publicJwk: JsonWebKey;
  privateJwk: JsonWebKey;
  createdAt: string;
  /** Cached gs_ session (revived instead of re-proving when valid). */
  session?: { token: string; expiresAt: string };
}

/** Bytes-level storage the keystore encrypts onto. */
export interface KeystoreStorage {
  get(key: string): Promise<string | null>;
  set(key: string, value: string): Promise<void>;
}

/** A device account as returned by create/recover. */
export interface DeviceAccount {
  did: string;
  handle: string;
  /** The `gs_` session token (a bearer until sessionExpiresAt). */
  session: string;
  sessionExpiresAt: string;
  /** A `ps_` panel session, minted only when the DID is a panel admin. */
  panelSession?: string;
  /** The keystore the keys live in. */
  keystore: Keystore;
  /**
   * Joins a room as this account — the same `Room` surface as
   * `Openfire.join()`. When the account was minted for a different
   * room (or none), it re-proves the recovery key first and joins with
   * the fresh token.
   */
  joinRoom(options: { roomKey: string; name: string } & Partial<RoomOptions>): Promise<Room>;
}

export interface Keystore {
  load(): Promise<KeystoreEntry | null>;
  save(entry: KeystoreEntry): Promise<void>;
  clear(): Promise<void>;
}

// ---- Crypto plumbing -------------------------------------------------------

type Subtle = Crypto['subtle'];

/** WebCrypto when the runtime has it; Node's webcrypto otherwise. */
async function subtleCrypto(): Promise<Subtle> {
  const globalCrypto = (globalThis as { crypto?: Crypto }).crypto;
  if (globalCrypto?.subtle) return globalCrypto.subtle;
  // Node < 19 (or unusual bundles): node:crypto's webcrypto.
  const { webcrypto } = await import('node:crypto');
  return webcrypto.subtle;
}

/**
 * Generates a fresh ES256 (EC P-256) recovery keypair: WebCrypto when
 * available, a node:crypto fallback otherwise. Either path produces
 * the same JWK shape the node validates.
 */
export async function generateRecoveryKeyPair(): Promise<RecoveryKeyPair> {
  const globalCrypto = (globalThis as { crypto?: Crypto }).crypto;
  if (globalCrypto?.subtle) {
    const pair = await globalCrypto.subtle.generateKey(
      { name: 'ECDSA', namedCurve: 'P-256' },
      true,
      ['sign', 'verify'],
    ) as CryptoKeyPair;
    return {
      publicJwk: await globalCrypto.subtle.exportKey('jwk', pair.publicKey),
      privateJwk: await globalCrypto.subtle.exportKey('jwk', pair.privateKey),
    };
  }
  const { generateKeyPairSync } = await import('node:crypto');
  const { publicKey, privateKey } = generateKeyPairSync('ec', {
    namedCurve: 'prime256v1',
  });
  return {
    publicJwk: publicKey.export({ format: 'jwk' }) as JsonWebKey,
    privateJwk: privateKey.export({ format: 'jwk' }) as JsonWebKey,
  };
}

function b64url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function unb64url(value: string): Uint8Array {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

/** DER ECDSA-Sig-Value -> JOSE raw r||s (64 bytes). */
function derToRaw(der: Uint8Array): Uint8Array {
  if (der[0] !== 0x30) throw new Error('unexpected DER signature');
  let offset = 2;
  if (der[1] & 0x80) offset += der[1] & 0x7f;
  if (der[offset] !== 0x02) throw new Error('unexpected DER r integer tag');
  const rLength = der[offset + 1];
  const rStart = offset + 2;
  const r = normalizeInt(der.subarray(rStart, rStart + rLength));
  const sTag = rStart + rLength;
  if (der[sTag] !== 0x02) throw new Error('unexpected DER s integer tag');
  const sLength = der[sTag + 1];
  const sStart = sTag + 2;
  const s = normalizeInt(der.subarray(sStart, sStart + sLength));
  return new Uint8Array([...r, ...s]);
  function normalizeInt(part: Uint8Array): Uint8Array {
    // Strip leading zero padding byte(s) used for positive DER sign bit.
    let i = 0;
    while (i < part.length - 1 && part[i] === 0 && part.length - i > 32) i++;
    const trimmed = part.subarray(i);
    const out = new Uint8Array(32);
    out.set(trimmed.subarray(Math.max(0, trimmed.length - 32)), Math.max(0, 32 - trimmed.length));
    return out;
  }
}

/**
 * Signs the recovery challenge: a compact ES256 JWS over
 * `{iss: did, sub: did, nonce, iat}` — exactly the payload the node's
 * `/ident/recover` verifies against the stored public JWK.
 */
export async function signRecoveryAssertion(
  privateJwk: JsonWebKey,
  did: string,
  nonce: string,
): Promise<string> {
  const subtle = await subtleCrypto();
  const header = b64url(new TextEncoder().encode(
    JSON.stringify({ alg: 'ES256', typ: 'JWT' })));
  const payload = b64url(new TextEncoder().encode(JSON.stringify({
    iss: did,
    sub: did,
    nonce,
    iat: Math.floor(Date.now() / 1000),
  })));
  const signingInput = new TextEncoder().encode(`${header}.${payload}`);
  const globalCrypto = (globalThis as { crypto?: Crypto }).crypto;
  if (globalCrypto?.subtle) {
    const key = await globalCrypto.subtle.importKey(
      'jwk', privateJwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
    // WebCrypto ECDSA emits raw r||s — the JOSE form already.
    const raw = new Uint8Array(
      await globalCrypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, signingInput));
    return `${header}.${payload}.${b64url(raw)}`;
  }
  const { createPrivateKey, sign } = await import('node:crypto');
  const key = createPrivateKey({ key: privateJwk, format: 'jwk' });
  const der = new Uint8Array(sign('sha256', signingInput, key));
  return `${header}.${payload}.${b64url(derToRaw(der))}`;
}

// ---- Keystore ---------------------------------------------------------------

/** In-memory storage: tests, Node CLIs, anything without IndexedDB. */
export function memoryStorage(): KeystoreStorage {
  const map = new Map<string, string>();
  return {
    async get(key) {
      return map.get(key) ?? null;
    },
    async set(key, value) {
      map.set(key, value);
    },
  };
}

/** IndexedDB-backed storage; null when the runtime has no IndexedDB. */
export function indexedDbStorage(
  dbName = 'openfire-keystore',
): KeystoreStorage | null {
  const indexedDB = (globalThis as { indexedDB?: IDBFactory }).indexedDB;
  if (!indexedDB) return null;
  const open = () =>
    new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open(dbName, 1);
      request.onupgradeneeded = () => {
        request.result.createObjectStore('identities');
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error ?? new Error('indexeddb open failed'));
    });
  const withStore = async (mode: IDBTransactionMode, run: (store: IDBObjectStore) => IDBRequest) => {
    const db = await open();
    try {
      return await new Promise((resolve, reject) => {
        const tx = db.transaction('identities', mode);
        const request = run(tx.objectStore('identities'));
        tx.oncomplete = () => resolve(request.result);
        tx.onerror = () => reject(tx.error ?? new Error('indexeddb transaction failed'));
      });
    } finally {
      db.close();
    }
  };
  return {
    async get(key) {
      return (await withStore('readonly', (store) => store.get(key))) as string | null;
    },
    async set(key, value) {
      await withStore('readwrite', (store) => store.put(value, key));
    },
  };
}

interface SealedRecord {
  v: 1;
  /** 'passphrase' | 'device' */
  mode: string;
  salt: string;
  iv: string;
  blob: string;
  /** device mode only: the wrapping key, stored alongside. */
  key?: string;
}

async function deriveAesKey(
  passphrase: string,
  salt: Uint8Array,
): Promise<CryptoKey> {
  const subtle = await subtleCrypto();
  const material = await subtle.importKey(
    'raw', new TextEncoder().encode(passphrase), 'PBKDF2', false, ['deriveKey']);
  return subtle.deriveKey(
    { name: 'PBKDF2', salt: salt as BufferSource, iterations: 150_000, hash: 'SHA-256' },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

async function fillRandomBytes(length: number): Promise<Uint8Array> {
  const bytes = new Uint8Array(length);
  const globalCrypto = (globalThis as { crypto?: Crypto }).crypto;
  if (globalCrypto?.getRandomValues) {
    globalCrypto.getRandomValues(bytes);
    return bytes;
  }
  const { randomBytes } = await import('node:crypto');
  bytes.set(new Uint8Array(randomBytes(length)));
  return bytes;
}

async function randomAesKey(): Promise<{ key: CryptoKey; raw: string }> {
  const subtle = await subtleCrypto();
  const bytes = await fillRandomBytes(32);
  const key = await subtle.importKey('raw', bytes as BufferSource, 'AES-GCM', false, ['encrypt', 'decrypt']);
  return { key, raw: b64url(bytes) };
}

async function aesKeyFromRaw(raw: string): Promise<CryptoKey> {
  const subtle = await subtleCrypto();
  return subtle.importKey('raw', unb64url(raw) as BufferSource, 'AES-GCM', false, ['encrypt', 'decrypt']);
}

/**
 * Opens the device-account keystore over [storage].
 *
 * Encryption at rest, two modes:
 * - with `passphrase`: AES-GCM under PBKDF2(150k, per-record salt) —
 *   real at-rest protection; a stolen storage blob is useless without
 *   the passphrase.
 * - without (v1 default): AES-GCM under a random device key stored in
 *   the SAME record. That protects the key material from casual export
 *   and copy-paste leakage, but NOT from an attacker who can read the
 *   storage wholesale — document the trade-off to players and offer
 *   the passphrase (and, later, the Bluesky link) as the real backup.
 *
 * Storage defaults to IndexedDB when the runtime has it, else memory
 * (callers on servers should inject their own).
 */
export function openKeystore(options: {
  storage?: KeystoreStorage;
  passphrase?: string;
  /** Record key; one device account per key by default. */
  key?: string;
} = {}): Keystore {
  const storage = options.storage ?? indexedDbStorage() ?? memoryStorage();
  const recordKey = options.key ?? 'device-account';

  async function seal(entry: KeystoreEntry): Promise<void> {
    const subtle = await subtleCrypto();
    const iv = await fillRandomBytes(12);
    const plaintext = new TextEncoder().encode(JSON.stringify(entry));
    let record: SealedRecord;
    if (options.passphrase !== undefined) {
      const salt = await fillRandomBytes(16);
      const aes = await deriveAesKey(options.passphrase, salt);
      record = {
        v: 1,
        mode: 'passphrase',
        salt: b64url(salt),
        iv: b64url(iv),
        blob: b64url(new Uint8Array(await subtle.encrypt(
          { name: 'AES-GCM', iv: iv as BufferSource }, aes, plaintext))),
      };
    } else {
      const { key, raw } = await randomAesKey();
      record = {
        v: 1,
        mode: 'device',
        salt: '',
        iv: b64url(iv),
        blob: b64url(new Uint8Array(await subtle.encrypt(
          { name: 'AES-GCM', iv: iv as BufferSource }, key, plaintext))),
        key: raw,
      };
    }
    await storage.set(recordKey, JSON.stringify(record));
  }

  return {
    async load() {
      const text = await storage.get(recordKey);
      if (text === null) return null;
      let record: SealedRecord;
      try {
        record = JSON.parse(text) as SealedRecord;
        if (record.v !== 1 || typeof record.blob !== 'string') return null;
      } catch {
        return null;
      }
      try {
        const subtle = await subtleCrypto();
        const aes = record.mode === 'passphrase'
          ? await deriveAesKey(options.passphrase ?? '', unb64url(record.salt))
          : await aesKeyFromRaw(record.key ?? '');
        const plaintext = await subtle.decrypt(
          { name: 'AES-GCM', iv: unb64url(record.iv) as BufferSource },
          aes,
          unb64url(record.blob) as BufferSource,
        );
        return JSON.parse(new TextDecoder().decode(plaintext)) as KeystoreEntry;
      } catch {
        // Wrong passphrase (or a tampered/corrupt record): nothing to load.
        return null;
      }
    },
    async save(entry) {
      await seal(entry);
    },
    async clear() {
      await storage.set(recordKey, '');
    },
  };
}

// ---- Device accounts ---------------------------------------------------------

async function identFetch(
  host: string,
  path: string,
  init?: RequestInit,
): Promise<{ status: number; body: Record<string, any> }> {
  const response = await fetch(new URL(path, host), init);
  const text = await response.text();
  let body: Record<string, any> = {};
  if (text !== '') {
    try {
      body = JSON.parse(text) as Record<string, any>;
    } catch {
      body = {};
    }
  }
  return { status: response.status, body };
}

function identError(what: string, result: { status: number; body: Record<string, any> }): Error {
  const message = (result.body?.error as { message?: string } | undefined)?.message;
  return new Error(`${what} failed (${result.status}): ${message ?? 'unknown error'}`);
}

export const deviceAccount = {
  /**
   * Ensures a device account exists on [host] and returns it. First
   * launch generates the keypair and creates the account; an existing
   * keystore entry is revived (recovered) instead — so calling this on
   * every boot is the intended pattern.
   */
  async create(options: {
    host: string;
    roomKey?: string;
    keystore?: Keystore;
    passphrase?: string;
  }): Promise<DeviceAccount> {
    const keystore = options.keystore ?? openKeystore({ passphrase: options.passphrase });
    const existing = await keystore.load();
    if (existing?.did && existing.privateJwk) {
      // Not the first launch on this device: bring the account back
      // (a still-valid cached session needs no network at all).
      if (existing.session && existing.session.expiresAt > new Date().toISOString()) {
        return buildAccount(options.host, {
          did: existing.did,
          handle: existing.handle,
          session: existing.session.token,
          sessionExpiresAt: existing.session.expiresAt,
        }, keystore, existing);
      }
      return proveAndMint(options.host, existing, keystore, options.roomKey);
    }
    const pair = await generateRecoveryKeyPair();
    const result = await identFetch(options.host, '/ident/device-account', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        rotationPubJwk: pair.publicJwk,
        room: options.roomKey,
      }),
    });
    if (result.status !== 200) throw identError('device account creation', result);
    return buildAccount(options.host, result.body, keystore, {
      publicJwk: pair.publicJwk,
      privateJwk: pair.privateJwk,
      createdAt: new Date().toISOString(),
    });
  },

  /**
   * Recovers the account in [keystore] on [host]: proves DID control
   * with the recovery key (nonce + signed assertion) and gets a fresh
   * session for the SAME did — the new-device / cleared-storage path.
   */
  async recover(options: {
    host: string;
    keystore: Keystore;
    roomKey?: string;
  }): Promise<DeviceAccount> {
    const entry = await options.keystore.load();
    if (!entry?.did || !entry.privateJwk) {
      throw new Error('recover: the keystore has no device account (create one first)');
    }
    return proveAndMint(options.host, entry, options.keystore, options.roomKey);
  },
};

async function proveAndMint(
  host: string,
  entry: KeystoreEntry,
  keystore: Keystore,
  roomKey?: string,
): Promise<DeviceAccount> {
  const nonce = await identFetch(
    host, `/ident/nonce?did=${encodeURIComponent(entry.did)}`);
  if (nonce.status !== 200) throw identError('recovery nonce', nonce);
  const assertion = await signRecoveryAssertion(
    entry.privateJwk, entry.did, nonce.body['nonce'] as string);
  const result = await identFetch(host, '/ident/recover', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      did: entry.did,
      nonce: nonce.body['nonce'],
      assertion,
      room: roomKey,
    }),
  });
  if (result.status !== 200) throw identError('recovery', result);
  if (result.body['did'] !== entry.did) {
    throw new Error('recovery returned a different did — refusing');
  }
  return buildAccount(host, result.body, keystore, {
    publicJwk: entry.publicJwk,
    privateJwk: entry.privateJwk,
    createdAt: entry.createdAt,
  });
}

/** Builds (and caches) the account from a create/recover response. */
async function buildAccount(
  host: string,
  body: Record<string, any>,
  keystore: Keystore,
  keys: { publicJwk: JsonWebKey; privateJwk: JsonWebKey; createdAt: string },
): Promise<DeviceAccount> {
  const did = body['did'] as string;
  const session = body['session'] as string;
  const sessionExpiresAt = body['sessionExpiresAt'] as string;
  await keystore.save({
    did,
    handle: body['handle'] as string,
    publicJwk: keys.publicJwk,
    privateJwk: keys.privateJwk,
    createdAt: keys.createdAt,
    session: { token: session, expiresAt: sessionExpiresAt },
  });
  let joinToken = body['joinToken'] as string | undefined;
  const mintedRoomKey = body['roomKey'] as string | undefined;
  const account: DeviceAccount = {
    did,
    handle: body['handle'] as string,
    session,
    sessionExpiresAt,
    panelSession: body['panelSession'] as string | undefined,
    keystore,
    async joinRoom(options) {
      if (mintedRoomKey === options.roomKey && joinToken) {
        const tokenToUse = joinToken;
        joinToken = undefined; // one-time token: never reuse on a second join
        return Room.join({
          ...options,
          host,
          roomKey: options.roomKey,
          joinToken: tokenToUse,
          name: options.name,
        });
      }
      // Different room (or none was minted): re-prove the recovery key
      // and join with the fresh token — the same DID, new credential.
      const fresh = await proveAndMint(
        host, (await keystore.load())!, keystore, options.roomKey);
      return fresh.joinRoom(options);
    },
  };
  return account;
}

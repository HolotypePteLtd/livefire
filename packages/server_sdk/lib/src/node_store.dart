import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sqlite3/sqlite3.dart';

import 'join_tokens.dart';
import 'sqlite_database.dart';

/// One persisted room row (see `docs/control_plane_api.md`).
class StoredRoom {
  StoredRoom({
    required this.roomId,
    required this.roomKey,
    required this.template,
    required this.config,
    required this.creatorToken,
    required this.status,
    required this.createdAt,
    this.ownerKeyId,
  });

  final String roomId;

  /// Unguessable; appears in the room URL.
  final String roomKey;
  final String template;

  /// The pinned config, verbatim JSON text.
  final String config;
  final String creatorToken;

  /// `live` or `closed` (draining is deferred).
  final String status;
  final DateTime createdAt;

  /// Owning API key id (null for legacy rows). Non-bootstrap keys are
  /// scoped to rooms they own; bootstrap keys see all rooms.
  final String? ownerKeyId;

  bool get live => status == 'live';
}

/// A cached AT Protocol profile row, keyed by DID (`docs/identity.md`).
/// Node-scoped cache; exposure to players is room-scoped via the roster.
class StoredProfile {
  StoredProfile({
    required this.did,
    required this.pds,
    required this.updatedAt,
    this.handle,
    this.displayName,
    this.avatar,
  });

  final String did;

  /// The PDS origin the profile was fetched from (for refreshes).
  final String pds;
  final String? handle, displayName, avatar;
  final DateTime updatedAt;

  /// What the roster's `members[].profile` carries.
  Map<String, dynamic> toProfileJson() => {
    'did': did,
    if (handle != null) 'handle': handle,
    if (displayName != null) 'displayName': displayName,
    if (avatar != null) 'avatar': avatar,
  };
}

/// A page of rooms plus the cursor for the next page (null on the last).
class RoomPage {
  RoomPage({required this.rooms, this.nextCursor});
  final List<StoredRoom> rooms;
  final String? nextCursor;
}

/// One API-key row (`api_keys` table). The plaintext key exists exactly
/// once — in the `POST /panel/api/keys` response that created it — and
/// never in this store: only its SHA-256 hash ([keyHash]) is persisted.
/// [keyPrefix] (first 8 characters) is the display form.
class StoredApiKey {
  StoredApiKey({
    required this.id,
    required this.label,
    required this.keyHash,
    required this.keyPrefix,
    required this.bootstrap,
    required this.createdAt,
    this.createdByDid,
    this.revokedAt,
    this.maxRooms,
    this.templates,
    this.roomsCreated = 0,
    this.tokensMinted = 0,
  });

  /// `ak_` + unguessable (panel-issued keys); `boot-<name>` for the
  /// read-only bootstrap rows seeded from the node config.
  final String id;
  final String label;
  final String keyHash;
  final String keyPrefix;

  /// True for keys seeded from `node.json` `apiKeys` — they cannot be
  /// revoked from the panel (removing them is a config change + restart).
  final bool bootstrap;
  final DateTime createdAt;

  /// The panel admin (DID) that created the key; null for bootstrap keys.
  final String? createdByDid;

  /// Null while the key is live.
  final DateTime? revokedAt;

  /// Key scopes (Postgres mode only; null = unlimited rooms / all
  /// templates). SQLite rows never carry scopes.
  final int? maxRooms;
  final List<String>? templates;

  /// Control-plane usage counters (rooms created / join tokens minted).
  final int roomsCreated;
  final int tokensMinted;

  bool get live => revokedAt == null;
}

/// The once-only result of creating a key: the stored record plus the
/// full plaintext key, shown to the creating admin exactly once.
class CreatedApiKey {
  CreatedApiKey({required this.record, required this.fullKey});
  final StoredApiKey record;

  /// `sk_` + 40 unguessable characters. Persisted nowhere.
  final String fullKey;
}

/// One `recovery_keys` row: the client-held recovery public key for a
/// device-account DID (`docs/identity.md` → guest identity ladder). Only
/// the JWK's hash is used for lookups/integrity; verification needs the
/// JWK itself, so it is stored too (public key material — safe to keep).
/// [guest] flags accounts created through `/ident/device-account`, so
/// guest identities stay distinguishable from upgraded ones later.
class StoredRecoveryKey {
  StoredRecoveryKey({
    required this.did,
    required this.pubkeyHash,
    required this.pubkeyJwk,
    required this.guest,
    required this.createdAt,
  });

  final String did;

  /// SHA-256 hex of the canonical public JWK text.
  final String pubkeyHash;

  /// The ES256 public JWK (`{kty, crv, x, y}`).
  final Map<String, dynamic> pubkeyJwk;

  final bool guest;
  final DateTime createdAt;
}

/// One `guest_credentials` row: the generated app password for a
/// device-account DID (`docs/identity.md` → guest identity ladder).
/// The node holds it so it can later write records into the guest's
/// repo (`com.atproto.server.createSession` as the guest) — the player
/// never sees it. Operator-held secret: see the identity docs' trust
/// note.
class StoredGuestCredential {
  StoredGuestCredential({
    required this.did,
    required this.handle,
    required this.password,
    required this.createdAt,
  });

  final String did;
  final String handle;
  final String password;
  final DateTime createdAt;
}

/// Key material generation shared by both persistence modes, so
/// panel-issued keys have the same shape everywhere: `sk_` + 40 and
/// `ak_` + 12 unguessable characters from a Crockford-ish alphabet,
/// and the SHA-256 hex hash under which keys are stored.
class ApiKeyMaterial {
  ApiKeyMaterial._();

  static const _alphabet =
      'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';

  static final Random _random = Random.secure();

  /// A full key: `sk_` + 40 unguessable characters.
  static String generateFullKey() => 'sk_${_unguessable(40)}';

  /// A key row id: `ak_` + 12 unguessable characters.
  static String generateId() => 'ak_${_unguessable(12)}';

  /// The storage form of a key: its SHA-256 hex hash, never the key.
  static String hash(String key) =>
      crypto.sha256.convert(utf8.encode(key)).toString();

  static String _unguessable(int length) => String.fromCharCodes([
        for (var i = 0; i < length; i++)
          _alphabet.codeUnitAt(_random.nextInt(_alphabet.length)),
      ]);
}

/// Node state over SQLite: a single database file in the node's data dir
/// (or `:memory:` in tests). Rooms and join-token consumption persist
/// across node restarts; room **state** does not (v0: reaped-room state is
/// in memory only — a restarted room resumes empty from its pinned config).
///
/// API keys live in `api_keys` **hash-only**: verification is a SHA-256
/// lookup on the presented bearer token, and the plaintext of a
/// panel-issued key is returned exactly once at creation. Bootstrap keys
/// from the static config are re-seeded (hashed) at every boot and are
/// read-only for the panel.
class NodeStore implements TokenLedger {
  NodeStore._(this._db);

  /// Opens (creating if needed) the database at [path] and ensures the
  /// schema. `:memory:` for tests.
  factory NodeStore.open(String path) {
    final db = openSqliteDatabase(path);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS rooms (
        room_id       TEXT PRIMARY KEY,
        room_key      TEXT NOT NULL UNIQUE,
        template      TEXT NOT NULL,
        config        TEXT NOT NULL,
        creator_token TEXT NOT NULL,
        status        TEXT NOT NULL,
        created_at    TEXT NOT NULL,
        owner_key_id  TEXT
      );
    ''');
    final roomColumns = {
      for (final row in db.select('PRAGMA table_info(rooms);'))
        row['name'] as String,
    };
    if (!roomColumns.contains('owner_key_id')) {
      db.execute('ALTER TABLE rooms ADD COLUMN owner_key_id TEXT;');
    }
    db.execute('''
      CREATE TABLE IF NOT EXISTS token_uses (
        jti     TEXT PRIMARY KEY,
        room_key TEXT NOT NULL,
        used_at TEXT NOT NULL
      );
    ''');
    _ensureApiKeySchema(db);
    db.execute('''
      CREATE TABLE IF NOT EXISTS recovery_keys (
        did         TEXT PRIMARY KEY,
        pubkey_hash TEXT NOT NULL,
        pubkey_jwk  TEXT NOT NULL,
        guest       INTEGER NOT NULL DEFAULT 1,
        created_at  TEXT NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS guest_credentials (
        did        TEXT PRIMARY KEY,
        handle     TEXT NOT NULL,
        password   TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS did_profiles (
        did          TEXT PRIMARY KEY,
        handle       TEXT,
        display_name TEXT,
        avatar       TEXT,
        pds          TEXT NOT NULL,
        updated_at   TEXT NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS handle_cache (
        handle     TEXT PRIMARY KEY,
        did        TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    return NodeStore._(db);
  }

  /// v1 `api_keys` (hash-only). Pre-panel databases shipped a plaintext
  /// `(key, name, created_at)` table whose rows were ephemeral copies of
  /// the config keys, rewritten by [seedApiKeys] at every boot — so the
  /// migration is a drop-and-recreate; the boot seed that follows
  /// restores the bootstrap rows (hashed).
  static void _ensureApiKeySchema(Database db) {
    final columns = {
      for (final row in db.select('PRAGMA table_info(api_keys);'))
        row['name'] as String,
    };
    if (columns.isNotEmpty && !columns.contains('key_hash')) {
      db.execute('DROP TABLE api_keys;');
    }
    db.execute('''
      CREATE TABLE IF NOT EXISTS api_keys (
        id             TEXT PRIMARY KEY,
        label          TEXT NOT NULL,
        key_hash       TEXT NOT NULL UNIQUE,
        key_prefix     TEXT NOT NULL,
        bootstrap      INTEGER NOT NULL DEFAULT 0,
        created_by_did TEXT,
        created_at     TEXT NOT NULL,
        revoked_at     TEXT,
        rooms_created  INTEGER NOT NULL DEFAULT 0,
        tokens_minted  INTEGER NOT NULL DEFAULT 0
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS api_keys_hash ON api_keys (key_hash);',
    );
  }

  final Database _db;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  StoredRoom _room(Row row) => StoredRoom(
    roomId: row['room_id'] as String,
    roomKey: row['room_key'] as String,
    template: row['template'] as String,
    config: row['config'] as String,
    creatorToken: row['creator_token'] as String,
    status: row['status'] as String,
    createdAt: DateTime.parse(row['created_at'] as String),
    ownerKeyId: row['owner_key_id'] as String?,
  );

  /// Persists a new live room.
  void insertRoom(StoredRoom room) {
    _db.execute(
      'INSERT INTO rooms (room_id, room_key, template, config, creator_token,'
      ' status, created_at, owner_key_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
      [
        room.roomId,
        room.roomKey,
        room.template,
        room.config,
        room.creatorToken,
        room.status,
        room.createdAt.toUtc().toIso8601String(),
        room.ownerKeyId,
      ],
    );
  }

  StoredRoom? roomById(String roomId) {
    final rows = _db.select(
      'SELECT room_id, room_key, template, config, creator_token, status,'
      ' created_at, owner_key_id FROM rooms WHERE room_id = ?;',
      [roomId],
    );
    return rows.isEmpty ? null : _room(rows.first);
  }

  StoredRoom? roomByKey(String roomKey) {
    final rows = _db.select(
      'SELECT room_id, room_key, template, config, creator_token, status,'
      ' created_at, owner_key_id FROM rooms WHERE room_key = ?;',
      [roomKey],
    );
    return rows.isEmpty ? null : _room(rows.first);
  }

  /// Assigns a pre-ownership room to a panel key. A repeat assignment
  /// to the same key succeeds without transferring an existing room.
  bool assignLegacyRoomOwner(String roomId, String keyId) {
    _db.execute(
      'UPDATE rooms SET owner_key_id = ?'
      ' WHERE room_id = ? AND owner_key_id IS NULL;',
      [keyId, roomId],
    );
    return _db.updatedRows == 1 || roomById(roomId)?.ownerKeyId == keyId;
  }

  /// Rooms, newest first, cursor-paginated (`docs/control_plane_api.md`
  /// → list rooms): [limit] rows at and strictly after [cursor]
  /// (`createdAt|roomId`, encoded), or from the top when null. When
  /// [ownerKeyId] is non-null, returns only rooms owned by that key.
  RoomPage listRooms({int limit = 50, String? cursor, String? ownerKeyId}) {
    String? cursorAt;
    String? cursorId;
    if (cursor != null) {
      try {
        final decoded =
            String.fromCharCodes(base64Url.decode(cursor)).split('|');
        if (decoded.length != 2) throw const FormatException('bad cursor');
        cursorAt = decoded[0];
        cursorId = decoded[1];
      } on FormatException {
        throw const FormatException('bad cursor');
      }
    }
    final where = <String>[];
    final args = <Object?>[];
    if (ownerKeyId != null) {
      where.add('owner_key_id = ?');
      args.add(ownerKeyId);
    }
    if (cursorAt != null) {
      where.add('(created_at < ? OR (created_at = ? AND room_id < ?))');
      args.addAll([cursorAt, cursorAt, cursorId]);
    }
    final whereClause = where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}';
    args.add(limit + 1);
    final rows = _db.select(
      'SELECT room_id, room_key, template, config, creator_token,'
      ' status, created_at, owner_key_id FROM rooms$whereClause'
      ' ORDER BY created_at DESC, room_id DESC LIMIT ?;',
      args,
    );
    final page = [for (final row in rows.take(limit)) _room(row)];
    final String? next = rows.length > limit
        ? encodeCursor(page.last.createdAt, page.last.roomId)
        : null;
    return RoomPage(rooms: page, nextCursor: next);
  }

  static String encodeCursor(DateTime createdAt, String roomId) =>
      base64Url.encode(
        '${createdAt.toUtc().toIso8601String()}|$roomId'.codeUnits,
      );

  /// Marks a room closed (drained). Idempotent.
  void closeRoom(String roomId) {
    _db.execute(
      "UPDATE rooms SET status = 'closed' WHERE room_id = ?;",
      [roomId],
    );
  }

  /// Live room count.
  int get liveRoomCount {
    final rows = _db.select(
      "SELECT COUNT(*) AS n FROM rooms WHERE status = 'live';",
    );
    return rows.first['n'] as int;
  }

  DateTime? _lastTokenPrune;

  /// Records a join-token nonce as consumed; false when already used.
  /// [TokenLedger] implementation — nonces are globally unique, the room
  /// key is recorded for audit only. Periodically prunes entries older than
  /// 25 hours (max joinTokenTtlSeconds is 24 h) so `token_uses` stays bounded.
  @override
  bool consume(String nonce, {String roomKey = ''}) {
    final now = DateTime.now().toUtc();
    if (_lastTokenPrune == null ||
        now.difference(_lastTokenPrune!) >= const Duration(hours: 1)) {
      _lastTokenPrune = now;
      pruneTokenUses(before: now.subtract(const Duration(hours: 25)));
    }
    _db.execute(
      'INSERT OR IGNORE INTO token_uses (jti, room_key, used_at)'
      ' VALUES (?, ?, ?);',
      [nonce, roomKey, now.toIso8601String()],
    );
    return _db.updatedRows == 1;
  }

  /// Drops consumed-token rows older than [before].
  void pruneTokenUses({required DateTime before}) {
    _db.execute('DELETE FROM token_uses WHERE used_at < ?;', [
      before.toUtc().toIso8601String(),
    ]);
  }

  // ---- API keys (hash-only; see [StoredApiKey]) -------------------------

  /// Replaces the **bootstrap** rows with [keys] (name → key) from the
  /// static node config, hashed. Panel-issued keys are untouched. Called
  /// at every boot; bootstrap rows are read-only everywhere else.
  void seedApiKeys(Map<String, String> keys) {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute('DELETE FROM api_keys WHERE bootstrap = 1;');
    final statement = _db.prepare(
      'INSERT INTO api_keys (id, label, key_hash, key_prefix, bootstrap,'
      ' created_by_did, created_at) VALUES (?, ?, ?, ?, 1, NULL, ?);',
    );
    for (final entry in keys.entries) {
      statement.execute([
        'boot-${entry.key}',
        entry.key,
        ApiKeyMaterial.hash(entry.value),
        entry.value.length >= 8 ? entry.value.substring(0, 8) : entry.value,
        now,
      ]);
    }
    statement.dispose();
  }

  /// Creates a panel-issued key. Returns the stored record plus the full
  /// plaintext key — which exists only in this result.
  CreatedApiKey createApiKey({
    required String label,
    String? createdByDid,
  }) {
    final fullKey = ApiKeyMaterial.generateFullKey();
    final record = StoredApiKey(
      id: ApiKeyMaterial.generateId(),
      label: label,
      keyHash: ApiKeyMaterial.hash(fullKey),
      keyPrefix: fullKey.substring(0, 8),
      bootstrap: false,
      createdAt: DateTime.now().toUtc(),
      createdByDid: createdByDid,
    );
    _db.execute(
      'INSERT INTO api_keys (id, label, key_hash, key_prefix, bootstrap,'
      ' created_by_did, created_at) VALUES (?, ?, ?, ?, 0, ?, ?);',
      [
        record.id,
        record.label,
        record.keyHash,
        record.keyPrefix,
        record.createdByDid,
        record.createdAt.toUtc().toIso8601String(),
      ],
    );
    return CreatedApiKey(record: record, fullKey: fullKey);
  }

  /// Verifies a presented bearer key: a live row whose hash matches.
  /// Bootstrap rows cover the config keys. Null when unknown/revoked.
  StoredApiKey? verifyApiKey(String key) {
    final rows = _db.select(
      'SELECT id, label, key_hash, key_prefix, bootstrap, created_by_did,'
      ' created_at, revoked_at, rooms_created, tokens_minted'
      ' FROM api_keys WHERE key_hash = ? AND revoked_at IS NULL;',
      [ApiKeyMaterial.hash(key)],
    );
    return rows.isEmpty ? null : _apiKey(rows.first);
  }

  /// Revokes a panel-issued key. False for unknown ids, bootstrap keys
  /// (config-owned) and already-revoked keys.
  bool revokeApiKey(String id) {
    _db.execute(
      "UPDATE api_keys SET revoked_at = ?"
      " WHERE id = ? AND bootstrap = 0 AND revoked_at IS NULL;",
      [DateTime.now().toUtc().toIso8601String(), id],
    );
    return _db.updatedRows == 1;
  }

  /// All key rows, bootstrap first, then panel keys newest first.
  List<StoredApiKey> listApiKeys() {
    final rows = _db.select(
      'SELECT id, label, key_hash, key_prefix, bootstrap, created_by_did,'
      ' created_at, revoked_at, rooms_created, tokens_minted'
      ' FROM api_keys ORDER BY bootstrap DESC, created_at DESC;',
    );
    return [for (final row in rows) _apiKey(row)];
  }

  /// Bumps the control-plane usage counters of [id] (cheap, same SQLite).
  void incrementApiKeyUsage(String id,
      {int roomsCreated = 0, int tokensMinted = 0}) {
    _db.execute(
      'UPDATE api_keys SET rooms_created = rooms_created + ?,'
      ' tokens_minted = tokens_minted + ? WHERE id = ?;',
      [roomsCreated, tokensMinted, id],
    );
  }

  // ---- Guest credentials (guest identity ladder, docs/identity.md) ----

  /// Persists (or replaces) the generated password for a device
  /// account DID — latest credentials win, since the node writes into
  /// the guest's repo with them.
  void upsertGuestCredential(StoredGuestCredential credential) {
    _db.execute(
      'INSERT INTO guest_credentials (did, handle, password, created_at)'
      ' VALUES (?, ?, ?, ?)'
      ' ON CONFLICT(did) DO UPDATE SET handle = excluded.handle,'
      ' password = excluded.password, created_at = excluded.created_at;',
      [
        credential.did,
        credential.handle,
        credential.password,
        credential.createdAt.toUtc().toIso8601String(),
      ],
    );
  }

  /// The stored credential for [did], or null.
  StoredGuestCredential? guestCredentialFor(String did) {
    final rows = _db.select(
      'SELECT did, handle, password, created_at FROM guest_credentials'
      ' WHERE did = ?;',
      [did],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return StoredGuestCredential(
      did: row['did'] as String,
      handle: row['handle'] as String,
      password: row['password'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  // ---- Recovery keys (guest identity ladder, docs/identity.md) --------

  /// Stores the recovery public key for a new device-account DID.
  /// Throws [StateError] when the DID already has one (v1: one recovery
  /// key per DID; rotation is a later slice) — the primary key is the
  /// race backstop, not the error path.
  void addRecoveryKey(StoredRecoveryKey key) {
    final existing = _db.select(
      'SELECT 1 FROM recovery_keys WHERE did = ?;',
      [key.did],
    );
    if (existing.isNotEmpty) {
      throw StateError('a recovery key already exists for ${key.did}');
    }
    try {
      _db.execute(
        'INSERT INTO recovery_keys (did, pubkey_hash, pubkey_jwk, guest,'
        ' created_at) VALUES (?, ?, ?, ?, ?);',
        [
          key.did,
          key.pubkeyHash,
          jsonEncode(key.pubkeyJwk),
          key.guest ? 1 : 0,
          key.createdAt.toUtc().toIso8601String(),
        ],
      );
    } on SqliteException catch (_) {
      throw StateError('a recovery key already exists for ${key.did}');
    }
  }

  /// The stored recovery key for [did], or null.
  StoredRecoveryKey? recoveryKeyFor(String did) {
    final rows = _db.select(
      'SELECT did, pubkey_hash, pubkey_jwk, guest, created_at'
      ' FROM recovery_keys WHERE did = ?;',
      [did],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return StoredRecoveryKey(
      did: row['did'] as String,
      pubkeyHash: row['pubkey_hash'] as String,
      pubkeyJwk:
          jsonDecode(row['pubkey_jwk'] as String) as Map<String, dynamic>,
      guest: (row['guest'] as int) == 1,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  StoredApiKey _apiKey(Row row) => StoredApiKey(
        id: row['id'] as String,
        label: row['label'] as String,
        keyHash: row['key_hash'] as String,
        keyPrefix: row['key_prefix'] as String,
        bootstrap: (row['bootstrap'] as int) == 1,
        createdAt: DateTime.parse(row['created_at'] as String),
        createdByDid: row['created_by_did'] as String?,
        revokedAt: row['revoked_at'] == null
            ? null
            : DateTime.parse(row['revoked_at'] as String),
        roomsCreated: row['rooms_created'] as int,
        tokensMinted: row['tokens_minted'] as int,
      );

  StoredProfile? _profile(Row row) => StoredProfile(
        did: row['did'] as String,
        pds: row['pds'] as String,
        updatedAt: DateTime.parse(row['updated_at'] as String),
        handle: row['handle'] as String?,
        displayName: row['display_name'] as String?,
        avatar: row['avatar'] as String?,
      );

  /// The cached profile for [did], or null. Callers apply their own TTL.
  StoredProfile? profile(String did) {
    final rows = _db.select(
      'SELECT did, handle, display_name, avatar, pds, updated_at'
      ' FROM did_profiles WHERE did = ?;',
      [did],
    );
    return rows.isEmpty ? null : _profile(rows.first);
  }

  /// Upserts the profile row for its DID.
  void saveProfile(StoredProfile profile) {
    _db.execute(
      'INSERT INTO did_profiles (did, handle, display_name, avatar, pds,'
      ' updated_at) VALUES (?, ?, ?, ?, ?, ?)'
      ' ON CONFLICT(did) DO UPDATE SET handle = excluded.handle,'
      ' display_name = excluded.display_name, avatar = excluded.avatar,'
      ' pds = excluded.pds, updated_at = excluded.updated_at;',
      [
        profile.did,
        profile.handle,
        profile.displayName,
        profile.avatar,
        profile.pds,
        profile.updatedAt.toUtc().toIso8601String(),
      ],
    );
  }

  /// Cached handle → DID (null when unknown or stale beyond [ttl]).
  String? cachedDidForHandle(String handle, {Duration ttl = _defaultHandleTtl}) {
    final rows = _db.select(
      'SELECT did, updated_at FROM handle_cache WHERE handle = ?;',
      [handle],
    );
    if (rows.isEmpty) return null;
    final at = DateTime.parse(rows.first['updated_at'] as String);
    if (DateTime.now().toUtc().difference(at) > ttl) return null;
    return rows.first['did'] as String;
  }

  /// Upserts the handle → DID cache row.
  void saveHandle(String handle, String did) {
    _db.execute(
      'INSERT INTO handle_cache (handle, did, updated_at) VALUES (?, ?, ?)'
      ' ON CONFLICT(handle) DO UPDATE SET did = excluded.did,'
      ' updated_at = excluded.updated_at;',
      [handle, did, DateTime.now().toUtc().toIso8601String()],
    );
  }

  static const _defaultHandleTtl = Duration(minutes: 10);
}

import 'dart:convert';

import 'package:server_sdk/server_sdk.dart';
import 'package:sqlite3/sqlite3.dart';

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

/// Persists the credentials and recovery keys created during device registration.
abstract interface class DeviceAccountStore {
  // ---- Guest credentials (guest identity ladder) -----------------------------

  /// Persists (or replaces) the generated app password for a device
  /// account DID — the credential the node uses to write into the
  /// guest's repo later (`createSession` as the guest).
  Future<void> addGuestCredential(StoredGuestCredential credential);

  /// The stored credential for [did], or null.
  Future<StoredGuestCredential?> guestCredentialFor(String did);

  // ---- Recovery keys (guest identity ladder) ---------------------------------

  /// Stores the recovery public key for a new device-account DID
  /// (`/ident/device-account`). v1: exactly one key per DID — an
  /// existing row is a conflict the caller reports (rotation is a
  /// later slice).
  Future<void> addRecoveryKey(StoredRecoveryKey key);

  /// The stored recovery key for [did], or null when the DID has none
  /// (unknown DID, or an upgraded account without one yet).
  Future<StoredRecoveryKey?> recoveryKeyFor(String did);
}

/// Uses the host's SQLite connection. Existing nodes reuse their account tables.
class SqliteAccountStore implements DeviceAccountStore {
  SqliteAccountStore(this._db) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS recovery_keys (
        did         TEXT PRIMARY KEY,
        pubkey_hash TEXT NOT NULL,
        pubkey_jwk  TEXT NOT NULL,
        guest       INTEGER NOT NULL DEFAULT 1,
        created_at  TEXT NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS guest_credentials (
        did        TEXT PRIMARY KEY,
        handle     TEXT NOT NULL,
        password   TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS did_profiles (
        did          TEXT PRIMARY KEY,
        handle       TEXT,
        display_name TEXT,
        avatar       TEXT,
        pds          TEXT NOT NULL,
        updated_at   TEXT NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS handle_cache (
        handle     TEXT PRIMARY KEY,
        did        TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
  }

  final Database _db;

  // ---- Guest credentials (guest identity ladder, docs/identity.md) ----

  /// Persists (or replaces) the generated password for a device
  /// account DID — latest credentials win, since the node writes into
  /// the guest's repo with them.
  @override
  Future<void> addGuestCredential(StoredGuestCredential credential) async {
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
  @override
  Future<StoredGuestCredential?> guestCredentialFor(String did) async {
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
  @override
  Future<void> addRecoveryKey(StoredRecoveryKey key) async {
    final existing = _db.select('SELECT 1 FROM recovery_keys WHERE did = ?;', [
      key.did,
    ]);
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
  @override
  Future<StoredRecoveryKey?> recoveryKeyFor(String did) async {
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
  String? cachedDidForHandle(
    String handle, {
    Duration ttl = _defaultHandleTtl,
  }) {
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

/// Uses the same Supabase RPCs and connection as the self-hosted node.
class SupabaseDeviceAccountStore implements DeviceAccountStore {
  SupabaseDeviceAccountStore(this._platform);

  final SupabasePlatformStore _platform;

  // ---- Guest credentials (guest identity ladder) --------------------------

  @override
  Future<void> addGuestCredential(StoredGuestCredential credential) async {
    await _platform.callRpc('panel_upsert_guest_credential', {
      'p_did': credential.did,
      'p_handle': credential.handle,
      'p_password': credential.password,
    });
  }

  @override
  Future<StoredGuestCredential?> guestCredentialFor(String did) async {
    final row = await _platform.callRpc('panel_get_guest_credential', {
      'p_did': did,
    });
    if (row is! Map<String, dynamic>) return null;
    return StoredGuestCredential(
      did: row['did'] as String,
      handle: row['handle'] as String,
      password: row['password'] as String,
      createdAt: DateTime.parse(row['createdAt'] as String),
    );
  }

  // ---- Recovery keys (guest identity ladder) -----------------------------

  @override
  Future<void> addRecoveryKey(StoredRecoveryKey key) async {
    // One key per DID: the SQL insert returns null when the DID already
    // has a row — the same conflict the SQLite mode's PK raises.
    final row = await _platform.callRpc('panel_register_recovery_key', {
      'p_did': key.did,
      'p_pubkey_hash': key.pubkeyHash,
      'p_pubkey_jwk': key.pubkeyJwk,
      'p_guest': key.guest,
    });
    if (row is! Map<String, dynamic>) {
      throw StateError('a recovery key already exists for ${key.did}');
    }
  }

  @override
  Future<StoredRecoveryKey?> recoveryKeyFor(String did) async {
    final row = await _platform.callRpc('panel_get_recovery_key', {
      'p_did': did,
    });
    if (row is! Map<String, dynamic>) return null;
    final jwk = row['pubkeyJwk'];
    return StoredRecoveryKey(
      did: row['did'] as String,
      pubkeyHash: row['pubkeyHash'] as String,
      pubkeyJwk: jwk is Map<String, dynamic>
          ? jwk
          : jsonDecode(jwk as String) as Map<String, dynamic>,
      guest: row['guest'] == true,
      createdAt: DateTime.parse(row['createdAt'] as String),
    );
  }
}

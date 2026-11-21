import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'node_store.dart';
import 'platform_store.dart';
import 'room_supervisor.dart' show RoomException;

/// Postgres persistence for the platform half (admins, API keys,
/// counters, audit log) over the shared self-hosted Supabase stack:
/// PostgREST RPC through the public Kong gateway, with the stack's
/// opaque service key in both `apikey` and `Authorization` headers
/// (Kong's request-transformer swaps it for the service-role JWT) —
/// configure it with `SUPABASE_URL` and `SUPABASE_SECRET_KEY`.
///
/// Selection is automatic: [fromEnvironment] returns this store only
/// when both variables are set; the node otherwise keeps SQLite
/// (byte-for-byte the old behavior). Room runtime state never moves —
/// it stays in the node's SQLite file.
///
/// Hot path: bearer-key verification and admin checks answer from an
/// in-memory cache seeded at [connect], refreshed after every panel
/// write and every [refreshTtl] (30 s). Room creation waits for the
/// atomic scope check and counter update in `panel_consume_room`.
/// Token counters are best-effort background writes.
///
/// Bootstrap keys from `node.json` `apiKeys` are hashed in memory only:
/// they verify like any key but never become Postgres rows (and so can
/// never be revoked from the panel).
class SupabasePlatformStore implements PlatformStore {
  SupabasePlatformStore._(
    this._rpc,
    this._bootstrap, {
    this.refreshTtl = const Duration(seconds: 30),
  });

  /// The RPC surface: `$url/rest/v1/rpc/<fn>` over HTTPS.
  final PostgrestRpc _rpc;

  final Map<String, StoredApiKey> _bootstrap; // hash -> row

  /// Cache TTL for key + admin snapshots.
  final Duration refreshTtl;

  Map<String, StoredApiKey> _byHash = const {};
  List<StoredApiKey> _rows = const [];
  List<StoredPanelAdmin> _admins = const [];
  Set<String> _activeAdmins = const {};

  Timer? _timer;
  bool _closed = false;

  /// Whether the last [connect] seeded `panel_admins` from the config
  /// (false = the database already carried the seed marker).
  bool seededAdmins = false;

  /// Reads the environment. Both
  /// `SUPABASE_URL` and `SUPABASE_SECRET_KEY` (or its
  /// `SUPABASE_SERVICE_KEY` alias) must be set and non-empty, else
  /// null — the caller falls back to the SQLite platform store.
  static Future<SupabasePlatformStore?> fromEnvironment({
    required Map<String, String> bootstrapKeys,
    required List<String> seedAdminDids,
    http.Client? httpClient,
    Duration refreshTtl = const Duration(seconds: 30),
  }) async {
    final env = Platform.environment;
    final url = env['SUPABASE_URL']?.trim() ?? '';
    final key = (env['SUPABASE_SECRET_KEY'] ?? env['SUPABASE_SERVICE_KEY'])
            ?.trim() ??
        '';
    if (url.isEmpty || key.isEmpty) return null;
    return connect(
      url,
      key,
      bootstrapKeys: bootstrapKeys,
      seedAdminDids: seedAdminDids,
      httpClient: httpClient,
      refreshTtl: refreshTtl,
    );
  }

  /// Connects and warms the cache. Throws [PlatformStoreException] when
  /// the stack is unreachable — the node refuses to start in Postgres
  /// mode rather than silently running keyless.
  static Future<SupabasePlatformStore> connect(
    String url,
    String serviceKey, {
    required Map<String, String> bootstrapKeys,
    required List<String> seedAdminDids,
    http.Client? httpClient,
    Duration refreshTtl = const Duration(seconds: 30),
  }) async {
    final store = SupabasePlatformStore._(
      PostgrestRpc(url, serviceKey, httpClient: httpClient),
      {
        for (final entry in bootstrapKeys.entries)
          ApiKeyMaterial.hash(entry.value): StoredApiKey(
            id: 'boot-${entry.key}',
            label: entry.key,
            keyHash: ApiKeyMaterial.hash(entry.value),
            keyPrefix: entry.value.length >= 8
                ? entry.value.substring(0, 8)
                : entry.value,
            bootstrap: true,
            createdAt: DateTime.now().toUtc(),
          ),
      },
      refreshTtl: refreshTtl,
    );
    // One-shot adminDids seed: on a fresh database the config DIDs are
    // inserted; afterwards the marker row makes this a no-op and the
    // database is the source of truth.
    final seeded = await store._rpc
        .call('panel_seed_admins', {'p_dids': seedAdminDids});
    store.seededAdmins = seeded is Map<String, dynamic> &&
        seeded['seeded'] == true;
    await store.refresh();
    store._timer = Timer.periodic(refreshTtl, (_) {
      unawaited(store.refresh().catchError((Object _) {}));
    });
    return store;
  }

  @override
  String get mode => 'postgres';

  @override
  bool get canManageAdmins => true;

  @override
  bool get hasAuditLog => true;

  // ---- Keys -------------------------------------------------------------

  @override
  StoredApiKey? verifyApiKey(String key) {
    final hash = ApiKeyMaterial.hash(key);
    return _bootstrap[hash] ?? _byHash[hash];
  }

  @override
  Future<CreatedApiKey> createApiKey({
    required String label,
    String? createdByDid,
    int? maxRooms,
    List<String>? templates,
  }) async {
    final fullKey = ApiKeyMaterial.generateFullKey();
    final id = ApiKeyMaterial.generateId();
    final row = await _rpc.call('panel_create_key', {
      'p_id': id,
      'p_label': label,
      'p_key_hash': ApiKeyMaterial.hash(fullKey),
      'p_key_prefix': fullKey.substring(0, 8),
      'p_created_by_did': createdByDid,
      'p_max_rooms': maxRooms,
      'p_templates': templates,
    });
    final record = _keyRow(row as Map<String, dynamic>);
    await refresh();
    return CreatedApiKey(record: record, fullKey: fullKey);
  }

  @override
  Future<bool> revokeApiKey(String id) async {
    final revoked =
        await _rpc.call('panel_revoke_key', {'p_id': id}) == true;
    if (revoked) await refresh();
    return revoked;
  }

  @override
  Future<List<StoredApiKey>> listApiKeys() async =>
      [..._bootstrap.values, ..._rows];

  @override
  Future<void> consumeRoom(StoredApiKey key, String template) async {
    if (key.bootstrap) return;
    const unavailable = RoomException(
      'unavailable',
      'room authorization is temporarily unavailable',
    );
    final Object? result;
    try {
      result = await _rpc
          .call('panel_consume_room', {'p_id': key.id, 'p_template': template})
          .timeout(const Duration(seconds: 5));
    } on Exception {
      throw unavailable;
    }
    if (result is! Map<String, dynamic>) throw unavailable;
    if (result['ok'] == false) {
      throw switch (result['code']) {
        'unknown_key' =>
          const RoomException('unauthorized', 'unknown or revoked key'),
        'room_limit' =>
          const RoomException('key_room_limit', 'API key room limit reached'),
        'template_not_allowed' => const RoomException(
          'key_template_not_allowed',
          'template is not allowed for this API key',
        ),
        _ => unavailable,
      };
    }
    final count = result['roomsCreated'];
    if (result['ok'] != true || count is! int) throw unavailable;

    // Concurrent RPC responses can arrive out of order. A revocation
    // that reached the cache while we waited must also be preserved.
    final current = _byHash[key.keyHash];
    if (current != null && count > current.roomsCreated) {
      _replaceCached(key.id, _withCounters(current, roomsCreated: count));
    }
  }

  @override
  Future<void> consumeToken(StoredApiKey key) async {
    if (key.bootstrap) return;
    _replaceCached(
      key.id,
      StoredApiKey(
        id: key.id,
        label: key.label,
        keyHash: key.keyHash,
        keyPrefix: key.keyPrefix,
        bootstrap: key.bootstrap,
        createdAt: key.createdAt,
        createdByDid: key.createdByDid,
        revokedAt: key.revokedAt,
        maxRooms: key.maxRooms,
        templates: key.templates,
        roomsCreated: key.roomsCreated,
        tokensMinted: key.tokensMinted + 1,
      ),
    );
    unawaited(
      _rpc
          .call('panel_consume_token', {'p_id': key.id})
          .then((row) {
        if (row is Map<String, dynamic> && row['ok'] == true) {
          final current = _byHash[key.keyHash] ?? key;
          _replaceCached(
            key.id,
            _withCounters(current, tokensMinted: row['tokensMinted'] as int?),
          );
        }
      }).catchError((Object _) {}),
    );
  }

  // ---- Admins -----------------------------------------------------------

  @override
  bool get hasAdmins => _activeAdmins.isNotEmpty;

  @override
  bool isAdmin(String did) => _activeAdmins.contains(did);

  @override
  Future<List<StoredPanelAdmin>> listAdmins() async => _admins;

  @override
  Future<AdminMutationResult> promoteAdmin({
    required String did,
    required String actorDid,
  }) async {
    final result = await _mutation(
      () => _rpc.call('panel_promote_admin', {'p_did': did, 'p_actor': actorDid}),
    );
    if (result.ok) await refresh();
    return result;
  }

  @override
  Future<AdminMutationResult> revokeAdmin({
    required String did,
    required String actorDid,
  }) async {
    final result = await _mutation(
      () => _rpc.call('panel_revoke_admin', {'p_did': did, 'p_actor': actorDid}),
    );
    if (result.ok) await refresh();
    return result;
  }

  Future<AdminMutationResult> _mutation(Future<Object?> Function() call) async {
    try {
      final row = await call();
      if (row is Map<String, dynamic>) {
        return AdminMutationResult(
          ok: row['ok'] == true,
          code: row['code'] as String?,
          admin: row['admin'] is Map<String, dynamic>
              ? _adminRow(row['admin'] as Map<String, dynamic>)
              : null,
        );
      }
    } on PlatformStoreException {
      return AdminMutationResult(ok: false, code: 'unavailable');
    }
    return AdminMutationResult(ok: false, code: 'unavailable');
  }

  // ---- Audit --------------------------------------------------------------

  @override
  Future<void> writeAudit({
    required String actorDid,
    required String action,
    String? targetType,
    String? targetId,
    Map<String, dynamic>? details,
  }) async {
    await _rpc.call('panel_audit', {
      'p_actor_did': actorDid,
      'p_action': action,
      'p_target_type': targetType,
      'p_target_id': targetId,
      'p_details': details,
    });
  }

  @override
  Future<List<StoredAuditEntry>> listAudit({int limit = 50}) async {
    final rows = await _rpc.call('panel_list_audit', {'p_limit': limit});
    if (rows is! List) return const [];
    return [for (final row in rows) _auditRow(row as Map<String, dynamic>)];
  }

  // ---- Guest credentials (guest identity ladder) --------------------------

  @override
  Future<void> addGuestCredential(StoredGuestCredential credential) async {
    await _rpc.call('panel_upsert_guest_credential', {
      'p_did': credential.did,
      'p_handle': credential.handle,
      'p_password': credential.password,
    });
  }

  @override
  Future<StoredGuestCredential?> guestCredentialFor(String did) async {
    final row = await _rpc.call('panel_get_guest_credential', {'p_did': did});
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
    final row = await _rpc.call('panel_register_recovery_key', {
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
    final row = await _rpc.call('panel_get_recovery_key', {'p_did': did});
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

  // ---- Cache ------------------------------------------------------------

  /// Reloads the key and admin snapshots. Awaited at [connect] and
  /// after every write; otherwise run by the TTL timer.
  Future<void> refresh() async {
    final results = await Future.wait([
      _rpc.call('panel_list_keys'),
      _rpc.call('panel_list_admins'),
    ]);
    final keys = results[0];
    final admins = results[1];
    if (keys is List) {
      _rows = [for (final row in keys) _keyRow(row as Map<String, dynamic>)];
      _byHash = {
        for (final key in _rows.where((k) => k.live)) key.keyHash: key,
      };
    }
    if (admins is List) {
      _admins = [
        for (final row in admins) _adminRow(row as Map<String, dynamic>),
      ];
      _activeAdmins = {
        for (final admin in _admins)
          if (admin.active) admin.did,
      };
    }
  }

  void _replaceCached(String id, StoredApiKey updated) {
    _rows = [
      for (final key in _rows)
        key.id == id ? updated : key,
    ];
    _byHash = {
      for (final key in _rows.where((k) => k.live)) key.keyHash: key,
    };
  }

  StoredApiKey _withCounters(
    StoredApiKey key, {
    int? roomsCreated,
    int? tokensMinted,
  }) =>
      StoredApiKey(
        id: key.id,
        label: key.label,
        keyHash: key.keyHash,
        keyPrefix: key.keyPrefix,
        bootstrap: key.bootstrap,
        createdAt: key.createdAt,
        createdByDid: key.createdByDid,
        revokedAt: key.revokedAt,
        maxRooms: key.maxRooms,
        templates: key.templates,
        roomsCreated: roomsCreated ?? key.roomsCreated,
        tokensMinted: tokensMinted ?? key.tokensMinted,
      );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _rpc.close();
  }

  // ---- Row mapping (the wire contract of migrations/0001) ---------------

  StoredApiKey _keyRow(Map<String, dynamic> row) => StoredApiKey(
        id: row['id'] as String,
        label: row['label'] as String,
        keyHash: row['keyHash'] as String,
        keyPrefix: row['keyPrefix'] as String,
        bootstrap: false,
        createdAt: DateTime.parse(row['createdAt'] as String),
        createdByDid: row['createdByDid'] as String?,
        revokedAt: row['revokedAt'] == null
            ? null
            : DateTime.parse(row['revokedAt'] as String),
        maxRooms: row['maxRooms'] as int?,
        templates: row['templates'] is List
            ? [for (final t in row['templates'] as List) t as String]
            : null,
        roomsCreated: row['roomsCreated'] as int? ?? 0,
        tokensMinted: row['tokensMinted'] as int? ?? 0,
      );

  StoredPanelAdmin _adminRow(Map<String, dynamic> row) => StoredPanelAdmin(
        did: row['did'] as String,
        addedByDid: row['addedByDid'] as String?,
        createdAt: row['createdAt'] == null
            ? null
            : DateTime.parse(row['createdAt'] as String),
        revokedAt: row['revokedAt'] == null
            ? null
            : DateTime.parse(row['revokedAt'] as String),
      );

  StoredAuditEntry _auditRow(Map<String, dynamic> row) => StoredAuditEntry(
        id: row['id'] as int?,
        ts: row['ts'] == null ? null : DateTime.parse(row['ts'] as String),
        actorDid: row['actorDid'] as String?,
        action: row['action'] as String,
        targetType: row['targetType'] as String?,
        targetId: row['targetId'] as String?,
        details: row['details'] is Map<String, dynamic>
            ? row['details'] as Map<String, dynamic>
            : null,
      );
}

/// The smallest viable Supabase client: hand-rolled PostgREST RPC
/// calls over Kong with the service key in both headers.
class PostgrestRpc {
  PostgrestRpc(String url, this.serviceKey, {http.Client? httpClient})
      : base = (url.endsWith('/') ? url.substring(0, url.length - 1) : url),
        _client = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  final String base;

  /// The stack's opaque service key; Kong swaps it for the service-role
  /// JWT, so it rides in `apikey` AND `Authorization`.
  final String serviceKey;

  final http.Client _client;
  final bool _ownsClient;

  /// Calls `POST /rest/v1/rpc/<fn>` with [args] (null values are
  /// stripped so SQL defaults apply). Returns the decoded JSON — a
  /// scalar, object, list or null (void functions).
  Future<Object?> call(String fn, [Map<String, Object?> args = const {}]) async {
    http.Response response;
    try {
      response = await _client.post(
        Uri.parse('$base/rest/v1/rpc/$fn'),
        headers: {
          'apikey': serviceKey,
          'Authorization': 'Bearer $serviceKey',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          for (final entry in args.entries)
            if (entry.value != null) entry.key: entry.value,
        }),
      );
    } catch (error) {
      throw PlatformStoreException('rpc $fn: unreachable ($error)');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PlatformStoreException(
          'rpc $fn -> ${response.statusCode}: ${response.body}');
    }
    if (response.body.isEmpty) return null;
    return jsonDecode(response.body);
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

/// The platform store is misconfigured or unreachable — fatal at boot,
/// surfaced as `unavailable` on best-effort paths.
class PlatformStoreException implements Exception {
  PlatformStoreException(this.message);
  final String message;

  @override
  String toString() => 'PlatformStoreException: $message';
}

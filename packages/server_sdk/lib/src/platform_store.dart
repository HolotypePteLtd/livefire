import 'dart:async';

import 'node_store.dart';

/// A panel admin row. In Postgres mode this is `panel_admins` (the
/// database is the source of truth after the one-time seed); in SQLite
/// mode it is a read-only view of the `adminDids` config list.
class StoredPanelAdmin {
  StoredPanelAdmin({
    required this.did,
    this.addedByDid,
    this.createdAt,
    this.revokedAt,
    this.readOnly = false,
  });

  final String did;

  /// The admin that promoted this DID; null for seeded admins.
  final String? addedByDid;
  final DateTime? createdAt;
  final DateTime? revokedAt;

  /// True when the row is a config-backed view (SQLite mode) and cannot
  /// change from the panel.
  final bool readOnly;

  bool get active => revokedAt == null;
}

/// One `panel_audit_log` row: what a panel admin did, when.
class StoredAuditEntry {
  StoredAuditEntry({
    this.id,
    this.ts,
    this.actorDid,
    required this.action,
    this.targetType,
    this.targetId,
    this.details,
  });

  final int? id;
  final DateTime? ts;
  final String? actorDid;
  final String action;
  final String? targetType;
  final String? targetId;
  final Map<String, dynamic>? details;
}

/// The result of an admin mutation. [ok] false always carries a machine
/// [code]: `self` (cannot revoke yourself), `last_admin` (cannot revoke
/// the last active admin), `not_found`, `invalid_did` — or `unavailable`
/// when the backing store cannot be reached.
class AdminMutationResult {
  AdminMutationResult({required this.ok, this.code, this.admin});
  final bool ok;
  final String? code;
  final StoredPanelAdmin? admin;
}

/// The platform/accounting half of the node's persistence: panel
/// admins, API keys (hash-only, scoped), usage counters and the audit
/// log. [NodeStore] keeps room configurations and consumed join tokens in
/// SQLite in both modes. Connected peers and game state live in memory.
///
/// Two implementations:
/// - [SqlitePlatformStore] — the default: everything in the node's own
///   SQLite database, byte-for-byte the pre-Supabase behavior (admins
///   from config, unscoped keys, no audit log);
/// - [SupabasePlatformStore] (`supabase_store.dart`) — Postgres over
///   the shared Supabase stack, selected automatically when
///   `SUPABASE_URL` + `SUPABASE_SECRET_KEY` are set in the
///   environment.
///
/// The hot path stays synchronous: [verifyApiKey] and [isAdmin] answer
/// from memory in both modes (the Postgres store keeps a short-TTL
/// cache — see its docs).
abstract class PlatformStore {
  /// `sqlite` or `postgres` — surfaced by the panel so the UI can show
  /// which features are available.
  String get mode;

  /// Whether admins can be promoted/revoked from the panel (Postgres
  /// mode only; SQLite mode owns the list via `adminDids` in config).
  bool get canManageAdmins;

  /// Whether an audit log exists at all.
  bool get hasAuditLog;

  // ---- API keys ------------------------------------------------------------

  /// Verifies a presented bearer key against the live (non-revoked)
  /// keys, hash-only. Synchronous and memory-backed: the Postgres store
  /// caches key hashes in process (refreshed on every panel write and
  /// on a short TTL), so bearer verification never hits the network.
  StoredApiKey? verifyApiKey(String key);

  /// Creates a panel-issued key. Returns the stored record plus the
  /// full plaintext key — which exists exactly once, in this result.
  /// [maxRooms]/[templates] are key scopes (null = unlimited / all);
  /// SQLite mode does not support scopes and throws.
  Future<CreatedApiKey> createApiKey({
    required String label,
    String? createdByDid,
    int? maxRooms,
    List<String>? templates,
  });

  /// Revokes a panel-issued key. False for unknown or already-revoked
  /// keys (and always false for bootstrap keys, which are config-owned).
  Future<bool> revokeApiKey(String id);

  /// All key rows, bootstrap first, then panel keys newest first.
  Future<List<StoredApiKey>> listApiKeys();

  /// Authorizes creation and increments the room counter. PostgreSQL
  /// checks the live key and scopes atomically. SQLite keys are unscoped.
  Future<void> consumeRoom(StoredApiKey key, String template);

  /// Token-mint accounting for [key]: best-effort increment of
  /// `tokens_minted`; never blocks the control-plane response.
  Future<void> consumeToken(StoredApiKey key);

  // ---- Admins ---------------------------------------------------------------

  /// Whether any admin exists (the panel's "enabled" gate together with
  /// the atproto provider).
  bool get hasAdmins;

  /// Whether [did] is an active admin. Memory-backed in both modes.
  bool isAdmin(String did);

  /// All admins (revoked included, newest active first).
  Future<List<StoredPanelAdmin>> listAdmins();

  /// Promotes [did] to admin (re-activating a revoked row when present).
  Future<AdminMutationResult> promoteAdmin({
    required String did,
    required String actorDid,
  });

  /// Revokes the admin [did] as [actorDid]. Guards (enforced in SQL in
  /// Postgres mode): an admin cannot revoke themselves, and the last
  /// active admin cannot be revoked.
  Future<AdminMutationResult> revokeAdmin({
    required String did,
    required String actorDid,
  });

  // ---- Audit -----------------------------------------------------------------

  /// Appends one audit row (one per mutating panel action; a no-op
  /// without an audit log).
  Future<void> writeAudit({
    required String actorDid,
    required String action,
    String? targetType,
    String? targetId,
    Map<String, dynamic>? details,
  });

  /// Recent audit rows, newest first.
  Future<List<StoredAuditEntry>> listAudit({int limit = 50});

  /// Releases resources (the Postgres store's TTL timer and HTTP
  /// client). Never closes the underlying [NodeStore].
  Future<void> close();
}

/// SQLite mode: exactly the pre-Supabase behavior. Keys delegate to the
/// node's own hash-only `api_keys` table, admins are the config's
/// `adminDids` (read-only), there is no audit log and no key scopes.
class SqlitePlatformStore implements PlatformStore {
  SqlitePlatformStore(this._store, {required List<String> adminDids})
      : _adminDids = List.unmodifiable(adminDids);

  final NodeStore _store;
  final List<String> _adminDids;

  @override
  String get mode => 'sqlite';

  @override
  bool get canManageAdmins => false;

  @override
  bool get hasAuditLog => false;

  @override
  StoredApiKey? verifyApiKey(String key) => _store.verifyApiKey(key);

  @override
  Future<CreatedApiKey> createApiKey({
    required String label,
    String? createdByDid,
    int? maxRooms,
    List<String>? templates,
  }) async {
    if (maxRooms != null || templates != null) {
      throw UnsupportedError(
          'scoped keys require the Postgres persistence mode '
          '(set SUPABASE_URL + SUPABASE_SECRET_KEY)');
    }
    return _store.createApiKey(label: label, createdByDid: createdByDid);
  }

  @override
  Future<bool> revokeApiKey(String id) async => _store.revokeApiKey(id);

  @override
  Future<List<StoredApiKey>> listApiKeys() async => _store.listApiKeys();

  @override
  Future<void> consumeRoom(StoredApiKey key, String template) async =>
      _store.incrementApiKeyUsage(key.id, roomsCreated: 1);

  @override
  Future<void> consumeToken(StoredApiKey key) async =>
      _store.incrementApiKeyUsage(key.id, tokensMinted: 1);

  @override
  bool get hasAdmins => _adminDids.isNotEmpty;

  @override
  bool isAdmin(String did) => _adminDids.contains(did);

  @override
  Future<List<StoredPanelAdmin>> listAdmins() async => [
        for (final did in _adminDids)
          StoredPanelAdmin(did: did, readOnly: true),
      ];

  @override
  Future<AdminMutationResult> promoteAdmin({
    required String did,
    required String actorDid,
  }) async =>
      AdminMutationResult(ok: false, code: 'config_owned');

  @override
  Future<AdminMutationResult> revokeAdmin({
    required String did,
    required String actorDid,
  }) async =>
      AdminMutationResult(ok: false, code: 'config_owned');

  @override
  Future<void> writeAudit({
    required String actorDid,
    required String action,
    String? targetType,
    String? targetId,
    Map<String, dynamic>? details,
  }) async {
    // No audit log in SQLite mode (nothing is stored anywhere).
  }

  @override
  Future<List<StoredAuditEntry>> listAudit({int limit = 50}) async => const [];

  @override
  Future<void> close() async {
    // The NodeStore is owned by the node process, not this store.
  }
}

/// Key-scope enforcement shared by both modes (a null scope = unlimited).
/// SQLite keys are always unscoped, so this is a no-op there; Postgres
/// keys carry the scopes from their `panel_api_keys` row.
extension KeyScopeCheck on StoredApiKey {
  /// The violation of creating a room from [template] with this key, or
  /// null when allowed. Codes are the control-plane error codes:
  /// `key_room_limit` (rooms_created has reached maxRooms) and
  /// `key_template_not_allowed` (template not in the key's set).
  ({String code, String message})? scopeViolationFor(String template) {
    final maxRooms = this.maxRooms;
    final templates = this.templates;
    if (maxRooms != null && roomsCreated >= maxRooms) {
      return (
        code: 'key_room_limit',
        message: 'key has reached its maxRooms limit ($maxRooms)',
      );
    }
    if (templates != null && !templates.contains(template)) {
      return (
        code: 'key_template_not_allowed',
        message: "key is not scoped for the '$template' template "
            '(allowed: ${templates.join(', ')})',
      );
    }
    return null;
  }
}

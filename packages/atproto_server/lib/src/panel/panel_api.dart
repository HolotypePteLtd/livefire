import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:server_sdk/server_sdk.dart';

import '../atproto/atproto_provider.dart';
import 'panel_assets.dart';

/// The node's developer panel, served same-origin at `/panel`.
///
/// **Authorization model (v0.1):** sign in with Bluesky through the same
/// atproto OAuth client the rooms use (`docs/identity.md`); a completed
/// panel sign-in mints a `ps_` session token (12 h, bearer) for the
/// verified DID. Admins are tracked by the node's [PlatformStore]:
/// in SQLite mode the `adminDids` config list (read-only); in Postgres
/// mode the `panel_admins` table — seeded once from the config, then
/// managed here (promote/revoke with last-admin and self guards). Every
/// other DID (and every guest) is refused. API keys are **never**
/// accepted here — the panel is a human surface, not a machine one.
///
/// With no admins (or no atproto provider) the panel is served but
/// disabled: the page and `/panel/api/session` say so, nothing else
/// works.
///
/// Bootstrap keys (config `apiKeys`) are listed read-only with a
/// `bootstrap` badge: they cannot be revoked from the panel — removing
/// one is a config change and a restart, by design. In Postgres mode
/// they are not database rows at all.
///
/// Every mutating panel action writes an audit row (`panel_audit_log`
/// in Postgres mode; SQLite mode has no audit log, so the write is a
/// no-op there).
class PanelApi {
  PanelApi({
    required this.store,
    required this.platform,
    required this.supervisor,
    required this.tokens,
    this.atproto,
    this.trustedProxies = const {},
  });

  final NodeStore store;

  /// Platform data: keys (scoped in Postgres mode), admins, audit.
  final PlatformStore platform;
  final RoomSupervisor supervisor;
  final JoinTokens tokens;

  /// The atproto provider (sign-in); null ⇒ panel disabled.
  final AtprotoAuthProvider? atproto;

  /// Reverse-proxy peer IPs trusted to supply `X-Forwarded-For`.
  final Set<String> trustedProxies;

  bool get enabled => platform.hasAdmins && atproto != null;

  bool isAdmin(String did) => platform.isAdmin(did);

  /// Handles `/panel` and `/panel/api/*`. Returns false when the path is
  /// not a panel route (caller 404s).
  Future<bool> handle(HttpRequest request) async {
    final path = request.uri.path;
    if (path != '/panel' && !path.startsWith('/panel/')) return false;
    try {
      if (path == '/panel' && request.method == 'GET') {
        await _html(request, panelPageHtml, 'text/html; charset=utf-8');
        return true;
      }
      if (path == '/panel/app.js' && request.method == 'GET') {
        await _html(request, panelAppJs, 'text/javascript; charset=utf-8');
        return true;
      }
      if (path == '/panel/panel.css' && request.method == 'GET') {
        await _html(request, panelCss, 'text/css; charset=utf-8');
        return true;
      }
      if (path == '/panel/api/session' && request.method == 'GET') {
        await _session(request);
        return true;
      }
      if (path == '/panel/api/auth/start' && request.method == 'GET') {
        await _authStart(request);
        return true;
      }
      if (path == '/panel/api/auth/result' && request.method == 'GET') {
        await _authResult(request);
        return true;
      }
      if (path == '/panel/api/keys' && request.method == 'GET') {
        final admin = await _requireAdmin(request);
        if (admin == null) return true;
        await _json(request, 200, {
          'keys': [for (final key in await platform.listApiKeys()) _keyJson(key)],
        });
        return true;
      }
      if (path == '/panel/api/keys' && request.method == 'POST') {
        final admin = await _requireAdmin(request);
        if (admin == null) return true;
        await _createKey(request, admin.did);
        return true;
      }
      final revoke = RegExp(r'^/panel/api/keys/([^/]+)/revoke$')
          .firstMatch(path);
      if (revoke != null && request.method == 'POST') {
        final admin = await _requireAdmin(request);
        if (admin == null) return true;
        await _revokeKey(request, revoke.group(1)!, admin.did);
        return true;
      }
      if (path == '/panel/api/rooms' && request.method == 'GET') {
        final admin = await _requireAdmin(request);
        if (admin == null) return true;
        await _json(request, 200, {'rooms': _roomsJson()});
        return true;
      }
      if (path == '/panel/api/admins' && request.method == 'GET') {
        final admin = await _requireAdmin(request);
        if (admin == null) return true;
        await _json(request, 200, {
          'canManage': platform.canManageAdmins,
          'admins': [
            for (final a in await platform.listAdmins()) _adminJson(a),
          ],
        });
        return true;
      }
      if (path == '/panel/api/admins' && request.method == 'POST') {
        final admin = await _requireAdmin(request);
        if (admin == null) return true;
        await _promoteAdmin(request, admin.did);
        return true;
      }
      final adminRevoke =
          RegExp(r'^/panel/api/admins/([^/]+)/revoke$').firstMatch(path);
      if (adminRevoke != null && request.method == 'POST') {
        final admin = await _requireAdmin(request);
        if (admin == null) return true;
        // DIDs carry ':' — the client percent-encodes it in the path.
        await _revokeAdmin(
            request, Uri.decodeComponent(adminRevoke.group(1)!), admin.did);
        return true;
      }
      if (path == '/panel/api/audit' && request.method == 'GET') {
        final admin = await _requireAdmin(request);
        if (admin == null) return true;
        if (!platform.hasAuditLog) {
          await _error(request, 404, 'not_found',
              'no audit log in SQLite persistence mode');
          return true;
        }
        final rawLimit = request.uri.queryParameters['limit'];
        var limit = 50;
        if (rawLimit != null) {
          final parsed = int.tryParse(rawLimit);
          if (parsed == null || parsed < 1 || parsed > 200) {
            await _error(request, 400, 'invalid_request', 'limit must be 1-200',
                field: 'limit');
            return true;
          }
          limit = parsed;
        }
        await _json(request, 200, {
          'entries': [
            for (final entry in await platform.listAudit(limit: limit))
              _auditJson(entry),
          ],
        });
        return true;
      }
      await _error(request, 404, 'not_found', 'unknown panel route');
      return true;
    } on _PanelBodyTooLarge {
      await _error(request, 413, 'payload_too_large', 'request body too large');
      return true;
    } catch (_) {
      await _error(request, 500, 'internal', 'internal error');
      return true;
    }
  }

  // ---- Sign-in ------------------------------------------------------------

  Future<void> _session(HttpRequest request) async {
    if (!enabled) {
      await _error(request, 503, 'panel_disabled',
          'panel disabled (no admins or no atproto provider)');
      return;
    }
    final session = _sessionOf(request);
    if (session == null) {
      await _error(request, 401, 'unauthorized', 'sign in with Bluesky');
      return;
    }
    if (!isAdmin(session.did)) {
      await _error(request, 403, 'forbidden', 'not a panel admin');
      return;
    }
    await _json(request, 200, {
      'did': session.did,
      'handle': ?session.handle,
      'admin': true,
      // The persistence mode drives what the UI offers: admin
      // management, scoped keys and the audit log are Postgres-only.
      'mode': platform.mode,
      'canManageAdmins': platform.canManageAdmins,
    });
  }

  Future<void> _authStart(HttpRequest request) async {
    final provider = atproto;
    if (provider == null) {
      await _error(
          request, 503, 'panel_disabled', 'atproto sign-in is disabled');
      return;
    }
    if (!platform.hasAdmins) {
      await _error(request, 503, 'panel_disabled', 'no admins configured');
      return;
    }
    final ip = resolveClientIp(request, trustedProxies: trustedProxies);
    if (!_throttle.allow(ip)) {
      await _error(request, 429, 'quota_exceeded', 'too many attempts');
      return;
    }
    final handle = (request.uri.queryParameters['handle'] ?? '').trim();
    if (handle.isEmpty) {
      await _error(request, 400, 'invalid_request', 'handle is required');
      return;
    }
    try {
      final flow = await provider.start(handle: handle, panel: true);
      await _json(request, 200, {
        'authorizationUrl': flow.authorizationUrl.toString(),
        'flow': flow.id,
        'expiresInMs':
            flow.expiresAt.difference(DateTime.now().toUtc()).inMilliseconds,
      });
    } on Exception {
      await _error(request, 400, 'invalid_request',
          'could not start sign-in for that handle');
    }
  }

  Future<void> _authResult(HttpRequest request) async {
    final provider = atproto;
    if (provider == null) {
      await _error(
          request, 503, 'panel_disabled', 'atproto sign-in is disabled');
      return;
    }
    final flow = provider.result(request.uri.queryParameters['flow'] ?? '');
    if (flow == null) {
      await _json(request, 202, {'status': 'pending'});
    } else if (flow['status'] == 'ok') {
      await _json(request, 200, flow);
    } else {
      // Operator surface: terminal sign-in failures were invisible here.
      stderr.writeln(
          'rooms-node: panel sign-in flow terminal: ${jsonEncode(flow)}');
      await _json(request, 410, flow);
    }
  }

  // ---- Keys ---------------------------------------------------------------

  Future<void> _createKey(HttpRequest request, String did) async {
    final body = await _jsonBody(request);
    final rawLabel = body?['label'];
    final label = rawLabel is String ? rawLabel.trim() : '';
    if (label.isEmpty || label.length > 64) {
      await _error(request, 400, 'invalid_request',
          'label is required (1-64 characters)');
      return;
    }
    int? maxRooms;
    if (body?['maxRooms'] != null) {
      final rawMaxRooms = body?['maxRooms'];
      if (rawMaxRooms is! int || rawMaxRooms < 0) {
        await _error(request, 400, 'invalid_request',
            'maxRooms must be a non-negative integer (null = unlimited)');
        return;
      }
      maxRooms = rawMaxRooms;
    }
    List<String>? templates;
    if (body?['templates'] != null) {
      final raw = body?['templates'];
      if (raw is! List || raw.any((t) => t is! String || t.isEmpty)) {
        await _error(request, 400, 'invalid_request',
            'templates must be a list of template names (null = all)');
        return;
      }
      templates = [for (final t in raw) t as String];
    }
    final CreatedApiKey created;
    try {
      created = await platform.createApiKey(
        label: label,
        createdByDid: did,
        maxRooms: maxRooms,
        templates: templates,
      );
    } on UnsupportedError {
      await _error(request, 400, 'invalid_request',
          'scoped keys require the Postgres persistence mode');
      return;
    }
    await _audit(did, 'key.create', 'api_key', created.record.id, {
      'label': label,
      'maxRooms': ?maxRooms,
      'templates': ?templates,
    });
    // The full plaintext appears exactly once — here and nowhere else.
    await _json(request, 201, {
      ..._keyJson(created.record),
      'key': created.fullKey,
    });
  }

  Future<void> _revokeKey(HttpRequest request, String id, String did) async {
    StoredApiKey? key;
    for (final k in await platform.listApiKeys()) {
      if (k.id == id) key = k;
    }
    if (key == null) {
      await _error(request, 404, 'not_found', 'unknown key');
      return;
    }
    if (key.bootstrap) {
      await _error(request, 403, 'forbidden',
          'bootstrap keys are config-owned; remove them from node.json');
      return;
    }
    if (!await platform.revokeApiKey(id)) {
      await _error(request, 409, 'conflict', 'key already revoked');
      return;
    }
    await _audit(did, 'key.revoke', 'api_key', id, {'label': key.label});
    await _json(request, 200, {
      'keys': [for (final k in await platform.listApiKeys()) _keyJson(k)],
    });
  }

  Map<String, dynamic> _keyJson(StoredApiKey key) => {
        'id': key.id,
        'label': key.label,
        'keyPrefix': key.keyPrefix,
        'bootstrap': key.bootstrap,
        'createdByDid': ?key.createdByDid,
        'createdAt': key.createdAt.toUtc().toIso8601String(),
        'revokedAt': ?key.revokedAt?.toUtc().toIso8601String(),
        'maxRooms': ?key.maxRooms,
        'templates': ?key.templates,
        'roomsCreated': key.roomsCreated,
        'tokensMinted': key.tokensMinted,
      };

  // ---- Admins (Postgres persistence mode) ---------------------------------

  Future<void> _promoteAdmin(HttpRequest request, String actorDid) async {
    if (!platform.canManageAdmins) {
      await _error(request, 403, 'forbidden',
          'admins are read-only in SQLite mode — edit adminDids in node.json '
          '(or set SUPABASE_URL + SUPABASE_SECRET_KEY for the Postgres mode)');
      return;
    }
    final provider = atproto;
    if (provider == null) {
      await _error(request, 503, 'panel_disabled', 'no atproto provider');
      return;
    }
    final body = await _jsonBody(request);
    final rawInput = body?['didOrHandle'];
    final input = rawInput is String ? rawInput.trim() : '';
    if (input.isEmpty) {
      await _error(request, 400, 'invalid_request',
          'didOrHandle is required (a did:plc:… DID or a handle)');
      return;
    }
    // A handle is resolved to its DID through the node's identity
    // resolver; a did: input is used as-is.
    final String did;
    final String? typedHandle;
    if (input.startsWith('did:')) {
      did = input;
      typedHandle = null;
    } else {
      try {
        final identity = await provider.resolveIdentity(input);
        did = identity.did;
        typedHandle = input;
      } on Exception {
        await _error(request, 400, 'invalid_request',
            'could not resolve "$input" to a DID');
        return;
      }
    }
    final result = await platform.promoteAdmin(did: did, actorDid: actorDid);
    if (!result.ok) {
      await _error(
          request, 400, 'invalid_request', _adminCodeMessage(result.code));
      return;
    }
    await _audit(actorDid, 'admin.promote', 'admin', did,
        typedHandle == null ? null : {'handle': typedHandle});
    await _json(request, 201, {
      'canManage': platform.canManageAdmins,
      'admins': [
        for (final a in await platform.listAdmins()) _adminJson(a),
      ],
    });
  }

  Future<void> _revokeAdmin(
      HttpRequest request, String did, String actorDid) async {
    if (!platform.canManageAdmins) {
      await _error(request, 403, 'forbidden',
          'admins are read-only in SQLite mode — edit adminDids in node.json '
          '(or set SUPABASE_URL + SUPABASE_SECRET_KEY for the Postgres mode)');
      return;
    }
    final result = await platform.revokeAdmin(did: did, actorDid: actorDid);
    if (!result.ok) {
      // The guards are policy, not server trouble: self-revoke and
      // last-admin map to 409, unknown DIDs to 404.
      final status = switch (result.code) {
        'self' || 'last_admin' => 409,
        'not_found' => 404,
        'unavailable' => 503,
        _ => 400,
      };
      await _error(request, status, 'conflict', _adminCodeMessage(result.code));
      return;
    }
    await _audit(actorDid, 'admin.revoke', 'admin', did);
    await _json(request, 200, {
      'canManage': platform.canManageAdmins,
      'admins': [
        for (final a in await platform.listAdmins()) _adminJson(a),
      ],
    });
  }

  String _adminCodeMessage(String? code) => switch (code) {
        'self' => 'you cannot revoke your own admin access',
        'last_admin' => 'cannot revoke the last active admin',
        'not_found' => 'not an active admin',
        'invalid_did' => 'that does not look like a DID',
        'config_owned' => 'admins are read-only in SQLite mode',
        'unavailable' => 'platform store unavailable — try again',
        _ => 'admin mutation failed',
      };

  Map<String, dynamic> _adminJson(StoredPanelAdmin admin) => {
        'did': admin.did,
        'addedByDid': ?admin.addedByDid,
        'createdAt': ?admin.createdAt?.toUtc().toIso8601String(),
        'revokedAt': ?admin.revokedAt?.toUtc().toIso8601String(),
        'active': admin.active,
        'readOnly': admin.readOnly,
      };

  // ---- Rooms (read-only) ----------------------------------------------------

  List<Map<String, dynamic>> _roomsJson() {
    final page = store.listRooms(limit: 50);
    return [
      for (final room in page.rooms)
        () {
          final live = supervisor.room(room.roomKey);
          final config =
              jsonDecode(room.config) as Map<String, dynamic>;
          return {
            'roomId': room.roomId,
            'template': room.template,
            'status': room.live ? 'live' : 'closed',
            'peers': live?.peerCount ?? 0,
            'capacity': live?.capacity ?? config['capacity'],
            'createdAt': room.createdAt.toUtc().toIso8601String(),
            'ageSeconds':
                DateTime.now().toUtc().difference(room.createdAt).inSeconds,
          };
        }(),
    ];
  }

  // ---- Audit ---------------------------------------------------------------

  Map<String, dynamic> _auditJson(StoredAuditEntry entry) => {
        'id': ?entry.id,
        'ts': ?entry.ts?.toUtc().toIso8601String(),
        'actorDid': ?entry.actorDid,
        'action': entry.action,
        'targetType': ?entry.targetType,
        'targetId': ?entry.targetId,
        'details': ?entry.details,
      };

  /// One audit row per mutating panel action. Best-effort by design:
  /// a failing audit write must not fail an action that already
  /// succeeded — but it is awaited so tests and normal operation see
  /// consistent ordering.
  Future<void> _audit(String actorDid, String action, String targetType,
      String targetId, [Map<String, dynamic>? details]) async {
    try {
      await platform.writeAudit(
        actorDid: actorDid,
        action: action,
        targetType: targetType,
        targetId: targetId,
        details: details,
      );
    } on Exception {
      // See doc above: audit is observability, not a gate.
    }
  }

  // ---- Auth plumbing --------------------------------------------------------

  final _throttle = IpThrottle(maxPerWindow: 30);

  /// The verified panel session, or null. Only `ps_` tokens count — an
  /// API key in the Authorization header is not a panel credential.
  PanelSession? _sessionOf(HttpRequest request) {
    final header =
        request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ps_')) return null;
    final check = tokens.verifyPanelSession(
      header.substring(7).trim(),
      now: DateTime.now().toUtc(),
    );
    return check.ok ? check.session : null;
  }

  Future<PanelSession?> _requireAdmin(HttpRequest request) async {
    if (!enabled) {
      await _error(request, 503, 'panel_disabled',
          'panel disabled (no admins or no atproto provider)');
      return null;
    }
    final session = _sessionOf(request);
    if (session == null) {
      await _error(request, 401, 'unauthorized', 'sign in with Bluesky');
      return null;
    }
    if (!isAdmin(session.did)) {
      await _error(request, 403, 'forbidden', 'not a panel admin');
      return null;
    }
    return session;
  }

  // ---- Response helpers -------------------------------------------------------

  static const _maxBodyBytes = 64 * 1024;

  Future<Map<String, dynamic>?> _jsonBody(HttpRequest request) async {
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in request) {
        if (builder.length + chunk.length > _maxBodyBytes) {
          throw const _PanelBodyTooLarge();
        }
        builder.add(chunk);
      }
      if (builder.isEmpty) return null;
      final text = utf8.decode(builder.takeBytes());
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _html(
      HttpRequest request, String body, String contentType) async {
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.parse(contentType);
    request.response.headers.set('Cache-Control', 'no-store');
    // No inline script/style anywhere on the page: everything loads from
    // this origin only, so a reflected-value XSS has no execution path.
    request.response.headers.set('Content-Security-Policy',
        "default-src 'self'; script-src 'self'; style-src 'self'; "
        "connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'");
    request.response.headers
        .set('X-Content-Type-Options', 'nosniff');
    request.response.write(body);
    await request.response.close();
  }

  Future<void> _error(
      HttpRequest request, int status, String code, String message,
      {String? field}) {
    return _json(request, status, {
      'error': {'code': code, 'message': message, 'field': ?field},
    });
  }

  Future<void> _json(
      HttpRequest request, int status, Map<String, dynamic> body) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

class _PanelBodyTooLarge implements Exception {
  const _PanelBodyTooLarge();
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An in-test stand-in for the Supabase stack: an HTTP server speaking
/// the PostgREST RPC surface (`POST /rest/v1/rpc/<fn>`, `apikey` +
/// `Authorization` service-key headers) with the SAME semantics the
/// migration's SQL implements — keys (hash-only, scoped), counters,
/// admin guards, seeding marker, audit log.
///
/// Coverage split (see supabase/contract_test.sh for the other half):
/// this stub lets the Dart store and the panel be exercised end-to-end
/// without Kong; the contract tests prove the real SQL behind it
/// answers identically.
class FakeSupabase {
  FakeSupabase(this.serviceKey, {this.latency = Duration.zero});

  final String serviceKey;

  /// Injected per-call latency for RPC timing tests.
  final Duration latency;
  bool rejectRoomRpc = false;

  final _keys = <String, Map<String, dynamic>>{}; // id -> row
  final _admins = <String, Map<String, dynamic>>{}; // did -> row
  final _recoveryKeys = <String, Map<String, dynamic>>{}; // did -> row
  final _guestCredentials = <String, Map<String, dynamic>>{}; // did -> row
  final _audit = <Map<String, dynamic>>[];
  bool _seededAdmins = false;
  HttpServer? _server;

  /// Every call: (function, args) — for request-shape assertions.
  final calls = <(String, Map<String, dynamic>)>[];

  String get origin =>
      'http://127.0.0.1:${_server!.port}'; // Kong is https in production

  Future<void> start() async {
    final server = _server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) => unawaited(_handle(request)));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  // ---- Test helpers -------------------------------------------------------

  /// Inserts a key row directly (as if a previous node run created it).
  void addKey(
    String id, {
    required String label,
    required String keyHash,
    String keyPrefix = 'sk_direct',
    String? createdByDid,
    int? maxRooms,
    List<String>? templates,
    int roomsCreated = 0,
    int tokensMinted = 0,
    bool revoked = false,
  }) {
    _keys[id] = {
      'id': id,
      'label': label,
      'keyHash': keyHash,
      'keyPrefix': keyPrefix,
      'createdByDid': createdByDid,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'revokedAt': revoked ? DateTime.now().toUtc().toIso8601String() : null,
      'maxRooms': maxRooms,
      'templates': templates,
      'roomsCreated': roomsCreated,
      'tokensMinted': tokensMinted,
    };
  }

  void addAdmin(String did, {String? addedByDid, bool revoked = false}) {
    _admins[did] = {
      'did': did,
      'addedByDid': addedByDid,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'revokedAt': revoked ? DateTime.now().toUtc().toIso8601String() : null,
    };
  }

  // ---- The RPC surface ------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    if (request.method != 'POST' ||
        !request.uri.path.startsWith('/rest/v1/rpc/')) {
      _respond(request, 404, {'message': 'not found'});
      return;
    }
    if (request.headers.value('apikey') != serviceKey ||
        request.headers.value('authorization') != 'Bearer $serviceKey') {
      _respond(request, 401, {'message': 'Missing or incorrect apikey'});
      return;
    }
    final fn = request.uri.path.substring('/rest/v1/rpc/'.length);
    final body = await utf8.decoder.bind(request).join();
    Map<String, dynamic> args;
    try {
      final decoded = body.isEmpty ? <String, dynamic>{} : jsonDecode(body);
      args = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on FormatException {
      _respond(request, 400, {'message': 'bad json'});
      return;
    }
    calls.add((fn, Map<String, dynamic>.from(args)));
    if (rejectRoomRpc && fn == 'panel_consume_room') {
      _respond(request, 503, {'message': 'database unavailable'});
      return;
    }
    if (latency != Duration.zero) {
      await Future<void>.delayed(latency);
    }
    try {
      final Object? result = _invoke(fn, args);
      _respond(request, 200, result ?? '');
    } on _RpcError catch (error) {
      _respond(request, error.status, {'message': error.message});
    }
  }

  void _respond(HttpRequest request, int status, Object body) {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(body is String ? body : jsonEncode(body));
    request.response.close();
  }

  Object? _invoke(String fn, Map<String, dynamic> args) {
    switch (fn) {
      case 'panel_register_recovery_key':
        final did = args['p_did'] as String? ?? '';
        if (_recoveryKeys.containsKey(did)) return null;
        final row = {
          'did': did,
          'pubkeyHash': args['p_pubkey_hash'],
          'pubkeyJwk': args['p_pubkey_jwk'],
          'guest': args['p_guest'] as bool? ?? true,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        };
        _recoveryKeys[did] = row;
        return row;
      case 'panel_get_recovery_key':
        return _recoveryKeys[args['p_did']];
      case 'panel_upsert_guest_credential':
        final did = args['p_did'] as String? ?? '';
        final row = {
          'did': did,
          'handle': args['p_handle'],
          'password': args['p_password'],
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        };
        _guestCredentials[did] = row;
        return row;
      case 'panel_get_guest_credential':
        return _guestCredentials[args['p_did']];
      case 'panel_list_keys':
        final rows = _keys.values.toList()
          ..sort((a, b) => (b['createdAt'] as String)
              .compareTo(a['createdAt'] as String));
        return rows;
      case 'panel_create_key':
        final label = args['p_label'] as String? ?? '';
        if (label.trim().isEmpty || label.length > 64) {
          throw const _RpcError(400, 'invalid label');
        }
        final row = {
          'id': args['p_id'],
          'label': label,
          'keyHash': args['p_key_hash'],
          'keyPrefix': args['p_key_prefix'],
          'createdByDid': args['p_created_by_did'],
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'revokedAt': null,
          'maxRooms': args['p_max_rooms'],
          'templates': args['p_templates'],
          'roomsCreated': 0,
          'tokensMinted': 0,
        };
        if (_keys.values.any((k) => k['keyHash'] == row['keyHash'])) {
          throw const _RpcError(
              409, 'duplicate key value violates unique constraint');
        }
        _keys[row['id'] as String] = row;
        return row;
      case 'panel_revoke_key':
        final key = _keys[args['p_id']];
        if (key == null || key['revokedAt'] != null) return false;
        key['revokedAt'] = DateTime.now().toUtc().toIso8601String();
        return true;
      case 'panel_consume_room':
        final key = _keys[args['p_id']];
        if (key == null || key['revokedAt'] != null) {
          return {'ok': false, 'code': 'unknown_key'};
        }
        final maxRooms = key['maxRooms'] as int?;
        final rooms = key['roomsCreated'] as int;
        if (maxRooms != null && rooms >= maxRooms) {
          return {
            'ok': false,
            'code': 'room_limit',
            'maxRooms': maxRooms,
            'roomsCreated': rooms,
          };
        }
        final templates = key['templates'] as List?;
        if (templates != null && !templates.contains(args['p_template'])) {
          return {
            'ok': false,
            'code': 'template_not_allowed',
            'template': args['p_template'],
          };
        }
        key['roomsCreated'] = rooms + 1;
        return {'ok': true, 'roomsCreated': rooms + 1};
      case 'panel_consume_token':
        final key = _keys[args['p_id']];
        if (key == null) return {'ok': false};
        key['tokensMinted'] = (key['tokensMinted'] as int) + 1;
        return {'ok': true, 'tokensMinted': key['tokensMinted']};
      case 'panel_seed_admins':
        if (_seededAdmins) return {'seeded': false};
        _seededAdmins = true;
        for (final did in (args['p_dids'] as List? ?? const [])) {
          _admins.putIfAbsent(
              did as String,
              () => {
                    'did': did,
                    'addedByDid': args['p_actor'],
                    'createdAt': DateTime.now().toUtc().toIso8601String(),
                    'revokedAt': null,
                  });
        }
        return {'seeded': true, 'dids': args['p_dids'] ?? const []};
      case 'panel_list_admins':
        return _admins.values.toList();
      case 'panel_promote_admin':
        final did = args['p_did'] as String? ?? '';
        if (!RegExp(r'^did:[a-z]+:.+').hasMatch(did)) {
          return {'ok': false, 'code': 'invalid_did'};
        }
        final existing = _admins[did];
        final admin = {
          'did': did,
          'addedByDid': args['p_actor'],
          'createdAt':
              existing?['createdAt'] ?? DateTime.now().toUtc().toIso8601String(),
          'revokedAt': null,
        };
        _admins[did] = admin;
        return {'ok': true, 'admin': admin};
      case 'panel_revoke_admin':
        final did = args['p_did'] as String;
        final actor = args['p_actor'] as String;
        if (did == actor) return {'ok': false, 'code': 'self'};
        final admin = _admins[did];
        if (admin == null || admin['revokedAt'] != null) {
          return {'ok': false, 'code': 'not_found'};
        }
        if (_admins.values.where((a) => a['revokedAt'] == null).length <= 1) {
          return {'ok': false, 'code': 'last_admin'};
        }
        admin['revokedAt'] = DateTime.now().toUtc().toIso8601String();
        return {'ok': true, 'admin': admin};
      case 'panel_audit':
        _audit.add({
          'id': _audit.length + 1,
          'ts': DateTime.now().toUtc().toIso8601String(),
          'actorDid': args['p_actor_did'],
          'action': args['p_action'],
          'targetType': args['p_target_type'],
          'targetId': args['p_target_id'],
          'details': args['p_details'] ?? const <String, dynamic>{},
        });
        return null;
      case 'panel_list_audit':
        final limit = ((args['p_limit'] as int?) ?? 50).clamp(1, 500);
        final rows = _audit.toList().reversed.toList();
        return rows.take(limit).toList();
      default:
        throw const _RpcError(404, 'function not found');
    }
  }
}

class _RpcError implements Exception {
  const _RpcError(this.status, this.message);
  final int status;
  final String message;
}

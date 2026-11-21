import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'node_store.dart';
import 'join_tokens.dart';
import 'platform_store.dart';
import 'room_supervisor.dart';

/// In-process control plane over the node's HTTP listener, implementing
/// `docs/control_plane_api.md` (v0 contract) on [NodeStore] +
/// [RoomSupervisor]. The hosted Workers implementation must behave
/// identically; this one exists so a single self-contained node serves
/// everything on one port.
class ControlPlaneApi {
  ControlPlaneApi({
    required this.supervisor,
    required this.store,
    required this.platform,
    required this.tokens,
    required this.publicBaseUrl,
    this.joinTokenTtl = const Duration(minutes: 15),
  });

  /// The supervised rooms (ops/metrics may read it).
  final RoomSupervisor supervisor;
  final NodeStore store;

  /// Platform data (API keys, scopes, counters): SQLite or the shared
  /// Supabase Postgres, chosen automatically from the environment.
  final PlatformStore platform;
  final JoinTokens tokens;

  /// Public base URL (`https://rooms.example.com`); room URLs are derived
  /// as `wss://…/play/<roomKey>` (http base → ws scheme).
  final String publicBaseUrl;
  final Duration joinTokenTtl;

  /// Handles `/v1/*` requests. Returns false when the path is not a
  /// control-plane route (caller 404s).
  Future<bool> handle(HttpRequest request) async {
    if (!request.uri.path.startsWith('/v1/')) return false;
    try {
      final key = _authorized(request);
      if (key == null) {
        return await _error(request, 401, 'unauthorized', 'missing or invalid key');
      }
      final segments = request.uri.path
          .split('/')
          .where((segment) => segment.isNotEmpty)
          .toList(); // e.g. ['v1', 'rooms', 'rm_x']
      if (segments.length < 2 || segments[0] != 'v1' || segments[1] != 'rooms') {
        return await _error(request, 404, 'not_found', 'unknown route');
      }
      if (segments.length == 2) {
        if (request.method == 'POST') return await _createRoom(request, key);
        if (request.method == 'GET') return await _listRooms(request, key);
        return await _error(request, 404, 'not_found', 'unknown route');
      }
      if (segments.length == 3) {
        final id = segments[2];
        if (request.method == 'GET') return await _lookupRoom(request, id, key);
        if (request.method == 'DELETE') {
          return await _deleteRoom(request, id, key);
        }
        return await _error(request, 404, 'not_found', 'unknown route');
      }
      if (segments.length == 4 &&
          segments[3] == 'tokens' &&
          request.method == 'POST') {
        return await _mintToken(request, segments[2], key);
      }
      if (segments.length == 4 &&
          segments[3] == 'owner' &&
          request.method == 'PUT') {
        return await _assignLegacyOwner(request, segments[2], key);
      }
      return await _error(request, 404, 'not_found', 'unknown route');
    } on _BodyTooLargeException {
      return await _error(
        request,
        413,
        'payload_too_large',
        'request body too large',
      );
    } on RoomException catch (e) {
      return await _error(request, _statusFor(e.code), e.code, e.message);
    } on FormatException catch (e) {
      return await _error(request, 422, 'invalid_config', e.message);
    } catch (e) {
      // Never leak internals.
      return await _error(request, 500, 'internal', 'internal error');
    }
  }

  /// Bearer verification: a SHA-256 lookup against the (hash-only)
  /// key store — bootstrap keys seeded from the config and panel-issued
  /// keys alike, revoked rows excluded. Memory-backed in both
  /// persistence modes (SQLite: local table; Postgres: in-process
  /// cache), so the hot path never waits on the network. Returns the
  /// key's row (for scopes + usage counters) or null.
  StoredApiKey? _authorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) return null;
    final key = header.substring(7).trim();
    if (key.isEmpty) return null;
    return platform.verifyApiKey(key);
  }

  Future<bool> _createRoom(HttpRequest request, StoredApiKey key) async {
    final body = await _jsonBody(request);
    if (body == null) {
      return await _error(request, 400, 'invalid_request', 'body must be JSON');
    }
    final template = body['template'];
    final config = body['config'];
    if (template is! String) {
      return _error(
        request, 400, 'invalid_request', 'template must be a string',
        field: 'template');
    }
    if (config is! Map<String, dynamic>) {
      return _error(
        request, 400, 'invalid_request', 'config must be an object',
        field: 'config');
    }
    // Key scopes (Postgres-issued keys only; unscoped keys and SQLite
    // keys pass trivially): past maxRooms or outside the template set
    // is a 403, not a quota 429 — the key is misused, not throttled.
    final violation = key.scopeViolationFor(template);
    if (violation != null) {
      return _error(
          request, 403, violation.code, violation.message,
          field: 'template');
    }
    // region is recorded-and-ignored in v0 (single region).
    final now = DateTime.now().toUtc();
    final creatorToken = 'ct_${_unguessable(24)}';
    final roomKey = _unguessable(24);
    supervisor.createRoom(
      template: template,
      config: config,
      creatorToken: creatorToken,
      roomKey: roomKey,
    );
    final stored = StoredRoom(
      roomId: 'rm_${_unguessable(8)}',
      roomKey: roomKey,
      template: template,
      config: jsonEncode(config),
      creatorToken: creatorToken,
      status: 'live',
      createdAt: now,
      ownerKeyId: key.id,
    );
    try {
      // Build and check node capacity first, then wait for quota approval
      // before making the room visible through the store or returning a token.
      await platform.consumeRoom(key, template);
      store.insertRoom(stored);
    } catch (_) {
      await supervisor.destroy(roomKey);
      rethrow;
    }
    final joinToken = tokens.mintJoin(roomKey, ttl: joinTokenTtl);
    return await _json(request, 201, {
      'roomId': stored.roomId,
      'roomKey': roomKey,
      'template': template,
      'url': _roomUrl(roomKey),
      'joinToken': joinToken,
      'joinTokenExpiresAt': _expiresAt(now),
      'creatorToken': creatorToken,
      'createdAt': _iso(now),
      'status': 'live',
    });
  }

  bool _canAccess(StoredApiKey key, StoredRoom room) =>
      key.bootstrap || room.ownerKeyId == key.id;

  Future<bool> _assignLegacyOwner(
    HttpRequest request,
    String roomId,
    StoredApiKey key,
  ) async {
    if (!key.bootstrap) {
      return _error(request, 403, 'forbidden', 'bootstrap key required');
    }
    if (store.roomById(roomId) == null) {
      return _error(request, 404, 'not_found', 'unknown room');
    }
    final body = await _jsonBody(request);
    final keyId = body?['keyId'];
    if (keyId is! String || keyId.isEmpty) {
      return _error(
        request,
        400,
        'invalid_request',
        'keyId is required',
        field: 'keyId',
      );
    }
    final keys = await platform.listApiKeys();
    if (!keys.any(
      (candidate) =>
          candidate.id == keyId && candidate.live && !candidate.bootstrap,
    )) {
      return _error(request, 404, 'not_found', 'unknown active panel key');
    }
    if (!store.assignLegacyRoomOwner(roomId, keyId)) {
      return _error(request, 409, 'conflict', 'room already has an owner');
    }
    request.response.statusCode = 204;
    await request.response.close();
    return true;
  }

  Future<bool> _mintToken(
      HttpRequest request, String roomId, StoredApiKey key) async {
    final room = store.roomById(roomId);
    if (room == null || !_canAccess(key, room)) {
      return await _error(request, 404, 'not_found', 'unknown room');
    }
    if (!room.live) {
      return await _error(request, 404, 'not_found', 'room is closed');
    }
    final body = await _jsonBody(request);
    final creator = body != null && body['creator'] == true;
    final now = DateTime.now().toUtc();
    final token = tokens.mintJoin(room.roomKey, ttl: joinTokenTtl);
    await platform.consumeToken(key);
    return await _json(request, 201, {
      'joinToken': token,
      'joinTokenExpiresAt': _expiresAt(now),
      if (creator) 'creatorToken': room.creatorToken,
    });
  }

  Future<bool> _lookupRoom(
    HttpRequest request,
    String roomId,
    StoredApiKey key,
  ) async {
    final room = store.roomById(roomId);
    if (room == null || !_canAccess(key, room)) {
      return await _error(request, 404, 'not_found', 'unknown room');
    }
    return await _json(
      request,
      200,
      _roomJson(room, withConfig: true, withOwner: key.bootstrap),
    );
  }

  Future<bool> _listRooms(HttpRequest request, StoredApiKey key) async {
    final query = request.uri.queryParameters;
    var limit = 50;
    if (query.containsKey('limit')) {
      final parsed = int.tryParse(query['limit']!);
      if (parsed == null || parsed < 1 || parsed > 200) {
        return _error(
          request, 400, 'invalid_request', 'limit must be 1-200',
          field: 'limit');
      }
      limit = parsed;
    }
    RoomPage page;
    try {
      page = store.listRooms(
        limit: limit,
        cursor: query['cursor'],
        ownerKeyId: key.bootstrap ? null : key.id,
      );
    } on FormatException {
      return _error(
        request, 400, 'invalid_request', 'malformed cursor',
        field: 'cursor');
    }
    return await _json(request, 200, {
      'rooms': [
        for (final room in page.rooms)
          _roomJson(room, withConfig: false, withOwner: key.bootstrap),
      ],
      if (page.nextCursor != null) 'nextCursor': page.nextCursor,
    });
  }

  Future<bool> _deleteRoom(
    HttpRequest request,
    String roomId,
    StoredApiKey key,
  ) async {
    final room = store.roomById(roomId);
    if (room == null || !_canAccess(key, room)) {
      return await _error(request, 404, 'not_found', 'unknown room');
    }
    if (room.live) {
      store.closeRoom(roomId);
      await supervisor.destroy(room.roomKey);
    }
    request.response.statusCode = 204;
    await request.response.close();
    return true;
  }

  Map<String, dynamic> _roomJson(
    StoredRoom room, {
    required bool withConfig,
    required bool withOwner,
  }) {
    final live = supervisor.room(room.roomKey);
    final config = jsonDecode(room.config) as Map<String, dynamic>;
    return {
      'roomId': room.roomId,
      'roomKey': room.roomKey,
      'template': room.template,
      'status': room.live ? 'live' : 'closed',
      'createdAt': _iso(room.createdAt),
      'peers': live?.peerCount ?? 0,
      'capacity': live?.capacity ?? config['capacity'],
      'url': _roomUrl(room.roomKey),
      if (withConfig) 'config': config,
      if (withOwner) 'ownerKeyId': room.ownerKeyId,
    };
  }

  String _roomUrl(String roomKey) {
    final base = publicBaseUrl.endsWith('/')
        ? publicBaseUrl.substring(0, publicBaseUrl.length - 1)
        : publicBaseUrl;
    final ws = base.startsWith('https://')
        ? 'wss://${base.substring(8)}'
        : base.startsWith('http://')
            ? 'ws://${base.substring(7)}'
            : base;
    return '$ws/play/$roomKey';
  }

  static const _maxBodyBytes =
      4 * 1024 * 1024; // 4 MiB (accommodates heightfields)

  Future<Map<String, dynamic>?> _jsonBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      if (builder.length + chunk.length > _maxBodyBytes) {
        throw const _BodyTooLargeException();
      }
      builder.add(chunk);
    }
    if (builder.isEmpty) return null;
    final text = utf8.decode(builder.takeBytes());
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  int _statusFor(String code) => switch (code) {
        'unauthorized' => 401,
        'not_found' => 404,
        'unsupported_template' => 422,
        'invalid_config' => 422,
        'invalid_request' => 400,
        'quota_exceeded' => 429,
        'key_room_limit' => 403,
        'key_template_not_allowed' => 403,
        'conflict' => 409,
        'unavailable' => 503,
        _ => 500,
      };

  Future<bool> _error(
    HttpRequest request,
    int status,
    String code,
    String message, {
    String? field,
  }) =>
      _json(request, status, {
        'error': {
          'code': code,
          'message': message,
          'field': ?field,
        },
      });

  Future<bool> _json(HttpRequest request, int status, Object body) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
    return true;
  }

  static String _iso(DateTime now) => now.toUtc().toIso8601String();

  String _expiresAt(DateTime mintedAt) => _iso(mintedAt.add(joinTokenTtl));

  static String _unguessable(int length) {
    const alphabet =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
    final random = Random.secure();
    return String.fromCharCodes([
      for (var i = 0; i < length; i++)
        alphabet.codeUnitAt(random.nextInt(alphabet.length)),
    ]);
  }
}

class _BodyTooLargeException implements Exception {
  const _BodyTooLargeException();
}

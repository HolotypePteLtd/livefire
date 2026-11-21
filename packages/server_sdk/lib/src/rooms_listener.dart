import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

import 'control_plane_api.dart';
import 'join_tokens.dart';
import 'listener_gates.dart';
import 'node_store.dart';
import 'room_supervisor.dart';
import 'server_socket_connection.dart';

/// Serves the room control API at `/v1/*` and room WebSockets at `/play/*`.
/// Subclasses can serve application routes through [handleAdditionalRequest].
///
/// The pre-upgrade gate chain, in order (nothing here faces the internet
/// without all of it):
/// 1. per-IP connection throttle (sliding window),
/// 2. Origin allowlist,
/// 3. join-token verification (signature, expiry, room binding),
/// 4. room resolution — live in the supervisor, or **lazily recreated**
///    from the pinned config when the store knows the room but the process
///    does not (node restart; state resets, the room key and config are
///    intact),
/// 5. capacity check,
/// 6. upgrade, then consume the token (one-time) — a lost consumption race
///    closes the socket immediately with `1008`.
///
/// DID-bearing join tokens (atproto provider) additionally set the hub
/// peer's adapter-verified identity to the token's DID: bans, moderation
/// eligibility and resume binding then key on the DID, and a guest token
/// cannot resume a DID-bound session.
class RoomsListener {
  RoomsListener({
    required this.supervisor,
    required this.api,
    required this.store,
    required this.tokens,
    required TokenLedger tokenLedger,
    required this.originGate,
    required this.throttle,
    this.onPeerAttached,
    this.trustedProxies = const {},
  }) : ledger = tokenLedger;

  /// Composed parts (public for ops/metrics wiring in the node binary).
  final RoomSupervisor supervisor;
  final ControlPlaneApi api;
  final NodeStore store;
  final JoinTokens tokens;
  final TokenLedger ledger;
  final OriginGate originGate;
  final IpThrottle throttle;

  /// Called after a peer completes its join handshake (any transport),
  /// with the room it joined. The node uses this to key peer ids to DIDs
  /// and prefetch profiles; errors here must not affect the room.
  final void Function(SupervisorRoom room, HubPeer peer)? onPeerAttached;

  /// Reverse-proxy peer IPs trusted to supply `X-Forwarded-For` (`'*'`
  /// trusts any direct proxy). Empty by default (direct peer IP only).
  final Set<String> trustedProxies;

  HttpServer? _http;
  bool _closed = false;

  bool get isClosed => _closed;

  /// The bound port (after [start]).
  int get port => _http!.port;

  Future<void> start({int port = 8787, Object address = '0.0.0.0'}) async {
    final server = _http = await HttpServer.bind(address, port, shared: false);
    server.listen(_request, onError: (Object _) {});
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _http?.close(force: true);
  }

  Future<void> _request(HttpRequest request) async {
    try {
      final path0 = request.uri.path;
      if (path0.startsWith('/v1/')) {
        if (!await api.handle(request)) {
          await writeError(request, 404, 'not_found', 'unknown route');
        }
        return;
      }
      final match = RegExp(r'^/play/([A-Za-z0-9_-]+)$')
          .firstMatch(request.uri.path);
      if (match != null && WebSocketTransformer.isUpgradeRequest(request)) {
        await _play(request, match.group(1)!);
        return;
      }
      if (await handleAdditionalRequest(request)) return;
      await writeError(request, 404, 'not_found', 'unknown route');
    } catch (_) {
      // The gate chain reports its own failures; anything else must not
      // leak internals or hang the connection.
      try {
        await writeError(request, 500, 'internal', 'internal error');
      } catch (_) {}
    }
  }

  /// Return true after handling a request outside the room API and WebSocket.
  Future<bool> handleAdditionalRequest(HttpRequest request) async => false;

  Future<void> _play(HttpRequest request, String roomKey) async {
    // 1. Per-IP throttle.
    final ip = resolveClientIp(request, trustedProxies: trustedProxies);
    if (!throttle.allow(ip)) {
      await writeError(request, 429, 'quota_exceeded', 'too many attempts');
      return;
    }
    // 2. Origin allowlist.
    if (!originGate.allowed(request.headers.value('Origin'))) {
      await writeError(request, 403, 'forbidden', 'origin not allowed');
      return;
    }
    // 3. Join token: valid, unexpired, bound to this room.
    final token = request.uri.queryParameters['token'];
    if (token == null || token.isEmpty) {
      await writeError(request, 401, 'unauthorized', 'missing join token');
      return;
    }
    final check = tokens.verify(
      token,
      roomKey: roomKey,
      now: DateTime.now().toUtc(),
    );
    if (!check.ok) {
      await writeError(
        request, 401, 'unauthorized', 'join token ${check.problem!.name}');
      return;
    }
    // 4. Room resolution (with lazy recreation after a node restart).
    var room = supervisor.room(roomKey);
    if (room == null) {
      room = _recreateRoom(roomKey);
      if (room == null) {
        await writeError(request, 404, 'not_found', 'unknown room');
        return;
      }
    }
    // 5. Capacity (connected peers only, so disconnected peers inside the
    //    resume grace window can still upgrade and resume on a full room;
    //    RoomHub._handshake enforces total capacity for new joins).
    if (room.connectedPeerCount >= room.capacity) {
      await writeError(request, 503, 'room_full', 'room is at capacity');
      return;
    }
    final joined = room;
    // 6. Upgrade, then make the token one-time.
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } on WebSocketException {
      return; // the handshake answer already went to the client
    }
    if (!ledger.consume(check.payload!.nonce)) {
      await socket.close(WebSocketStatus.policyViolation, 'token used');
      return;
    }
    final connection = ServerWebSocketConnection(socket);
    connection.start();
    // The verified DID (atproto tokens) becomes the hub peer's
    // adapter-verified identity: bans, moderation and resume bind to it.
    final identity = check.payload!.did;
    // Join handshake runs on the hub; failures close the transport there.
    unawaited(
      supervisor
          .attach(roomKey, connection, identity: identity)
          .then((peer) {
            if (peer != null && !_closed) onPeerAttached?.call(joined, peer);
          })
          .catchError((Object _) => null),
    );
  }

  /// Rebuilds a store-known live room after a node restart. State does not
  /// persist (v0); the pinned config and room key do.
  SupervisorRoom? _recreateRoom(String roomKey) {
    final stored = store.roomByKey(roomKey);
    if (stored == null || !stored.live) return null;
    try {
      return supervisor.createRoom(
        template: stored.template,
        config: jsonDecode(stored.config) as Map<String, dynamic>,
        creatorToken: stored.creatorToken,
        roomKey: roomKey,
      );
    } on Exception {
      return null;
    }
  }

  Future<void> writeError(
    HttpRequest request,
    int status,
    String code,
    String message,
  ) async {
    if (_closed) return;
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'error': {'code': code, 'message': message},
    }));
    await request.response.close();
  }
}

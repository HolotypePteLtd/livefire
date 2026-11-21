import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

import 'atproto/atproto_provider.dart';
import 'control_plane_api.dart';
import 'ident/guest_identity.dart';
import 'join_tokens.dart';
import 'listener_gates.dart';
import 'node_store.dart';
import 'panel/panel_api.dart';
import 'room_supervisor.dart';
import 'server_socket_connection.dart';

/// One HTTP listener serving everything a rooms node exposes:
///
/// - `/v1/*` — the control-plane API (`docs/control_plane_api.md`),
/// - `/play/<roomKey>?token=…` — the data plane: authenticated WebSocket
///   upgrades routed through the [RoomSupervisor],
/// - `/panel` — the developer panel (`panel/panel_api.dart`): API-key
///   management behind atproto sign-in, present only when [panel] is
///   wired,
/// - `/oauth/client.json`, `/oauth/jwks.json`, `/auth/start`,
///   `/auth/callback`, `/auth/result` — the atproto auth provider
///   (`docs/identity.md`), present only when [atproto] is wired;
/// - `/ident/nonce`, `/ident/device-account`, `/ident/recover` — the
///   guest identity ladder (`ident/guest_identity.dart`), present only
///   when [ident] is wired.
///
/// One port by design (single process behind a reverse proxy for TLS);
/// splitting control/data onto separate listeners is a deployment choice
/// that does not change the code paths.
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
    this.atproto,
    this.panel,
    this.ident,
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

  /// The atproto auth provider (`docs/identity.md`); null when the node
  /// runs guest tokens only.
  final AtprotoAuthProvider? atproto;

  /// The developer panel (`panel/panel_api.dart`); null when the
  /// embedder does not serve one (then `/panel*` is a plain 404).
  final PanelApi? panel;

  /// The guest identity ladder (`ident/guest_identity.dart`); null when
  /// the node does not offer device accounts (then `/ident*` is a 404).
  final GuestIdentityApi? ident;

  /// Called after a peer completes its join handshake (any transport),
  /// with the room it joined. The node uses this to key peer ids to DIDs
  /// and prefetch profiles; errors here must not affect the room.
  final void Function(SupervisorRoom room, HubPeer peer)? onPeerAttached;

  /// Reverse-proxy peer IPs trusted to supply `X-Forwarded-For` (`'*'`
  /// trusts any direct proxy). Empty by default (direct peer IP only).
  final Set<String> trustedProxies;

  HttpServer? _http;
  bool _closed = false;

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
          await _plainError(request, 404, 'not_found', 'unknown route');
        }
        return;
      }
      final match = RegExp(r'^/play/([A-Za-z0-9_-]+)$')
          .firstMatch(request.uri.path);
      if (match != null && WebSocketTransformer.isUpgradeRequest(request)) {
        await _play(request, match.group(1)!);
        return;
      }
      if (path0 == '/panel' || path0.startsWith('/panel/')) {
        if (panel != null && await panel!.handle(request)) return;
        await _plainError(request, 404, 'not_found', 'unknown route');
        return;
      }
      if (path0 == '/ident' || path0.startsWith('/ident/')) {
        if (ident != null && await ident!.handle(request)) return;
        await _plainError(request, 404, 'not_found', 'unknown route');
        return;
      }
      if (await _authRoutes(request)) return;
      await _plainError(request, 404, 'not_found', 'unknown route');
    } catch (_) {
      // The gate chain reports its own failures; anything else must not
      // leak internals or hang the connection.
      try {
        await _plainError(request, 500, 'internal', 'internal error');
      } catch (_) {}
    }
  }

  Future<void> _play(HttpRequest request, String roomKey) async {
    // 1. Per-IP throttle.
    final ip = resolveClientIp(request, trustedProxies: trustedProxies);
    if (!throttle.allow(ip)) {
      await _plainError(request, 429, 'quota_exceeded', 'too many attempts');
      return;
    }
    // 2. Origin allowlist.
    if (!originGate.allowed(request.headers.value('Origin'))) {
      await _plainError(request, 403, 'forbidden', 'origin not allowed');
      return;
    }
    // 3. Join token: valid, unexpired, bound to this room.
    final token = request.uri.queryParameters['token'];
    if (token == null || token.isEmpty) {
      await _plainError(request, 401, 'unauthorized', 'missing join token');
      return;
    }
    final check = tokens.verify(
      token,
      roomKey: roomKey,
      now: DateTime.now().toUtc(),
    );
    if (!check.ok) {
      await _plainError(
        request, 401, 'unauthorized', 'join token ${check.problem!.name}');
      return;
    }
    // 4. Room resolution (with lazy recreation after a node restart).
    var room = supervisor.room(roomKey);
    if (room == null) {
      room = _recreateRoom(roomKey);
      if (room == null) {
        await _plainError(request, 404, 'not_found', 'unknown room');
        return;
      }
    }
    // 5. Capacity (connected peers only, so disconnected peers inside the
    //    resume grace window can still upgrade and resume on a full room;
    //    RoomHub._handshake enforces total capacity for new joins).
    if (room.connectedPeerCount >= room.capacity) {
      await _plainError(request, 503, 'room_full', 'room is at capacity');
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

  /// The atproto auth surface. CORS-open (`*`): the flow id in
  /// `/auth/result` is an unguessable bearer, exactly like the one-time
  /// join token it hands out, so any origin may present one.
  Future<bool> _authRoutes(HttpRequest request) async {
    final provider = atproto;
    final path = request.uri.path;
    if (path == '/oauth/client.json' && request.method == 'GET') {
      if (provider == null) {
        return _plainErrorBool(
            request, 404, 'not_found', 'atproto auth disabled');
      }
      await _jsonNoStore(request, 200, provider.clientMetadata());
      return true;
    }
    if (path == '/oauth/jwks.json' && request.method == 'GET') {
      if (provider == null) {
        return _plainErrorBool(
            request, 404, 'not_found', 'atproto auth disabled');
      }
      await _jsonNoStore(request, 200, provider.publicJwks());
      return true;
    }
    if (path == '/auth/start' && request.method == 'GET') {
      if (provider == null) {
        return _plainErrorBool(
            request, 404, 'not_found', 'atproto auth disabled');
      }
      await _authStart(request, provider);
      return true;
    }
    if (path == '/auth/callback' && request.method == 'GET') {
      if (provider == null) {
        return _plainErrorBool(
            request, 404, 'not_found', 'atproto auth disabled');
      }
      await _authCallback(request, provider);
      return true;
    }
    if (path == '/auth/result' && request.method == 'GET') {
      if (provider == null) {
        return _plainErrorBool(
            request, 404, 'not_found', 'atproto auth disabled');
      }
      final flow = provider.result(request.uri.queryParameters['flow'] ?? '');
      if (flow == null) {
        await _jsonNoStore(request, 202, {'status': 'pending'});
      } else if (flow['status'] == 'ok') {
        await _jsonNoStore(request, 200, flow);
      } else {
        await _jsonNoStore(request, 410, flow);
      }
      return true;
    }
    return false;
  }

  Future<void> _authStart(
    HttpRequest request,
    AtprotoAuthProvider provider,
  ) async {
    final ip = resolveClientIp(request, trustedProxies: trustedProxies);
    if (!throttle.allow(ip)) {
      await _plainError(request, 429, 'quota_exceeded', 'too many attempts');
      return;
    }
    final params = request.uri.queryParameters;
    final handle = (params['handle'] ?? '').trim();
    final roomKey = params['room'] ?? '';
    final creator = params['creator'] == 'true';
    final creatorProof = params['creatorToken'];
    if (handle.isEmpty || roomKey.isEmpty) {
      await _plainError(request, 400, 'invalid_request',
          'handle and room are required');
      return;
    }
    final stored = store.roomByKey(roomKey);
    if (supervisor.room(roomKey) == null) {
      if (stored == null || !stored.live) {
        await _plainError(request, 404, 'not_found', 'unknown room');
        return;
      }
    }
    if (creator) {
      if (stored == null ||
          creatorProof == null ||
          creatorProof.isEmpty ||
          !secureEquals(creatorProof, stored.creatorToken)) {
        await _plainError(request, 403, 'forbidden',
            'creatorToken is required to claim room leadership');
        return;
      }
    }
    try {
      final flow = await provider.start(
        handle: handle,
        roomKey: roomKey,
        creator: creator,
      );
      if (params['format'] == 'json') {
        await _jsonNoStore(request, 200, {
          'authorizationUrl': flow.authorizationUrl.toString(),
          'flow': flow.id,
          'expiresInMs': flow.expiresAt.difference(DateTime.now().toUtc())
              .inMilliseconds,
        });
      } else {
        request.response.statusCode = 302;
        request.response.headers
            .set(HttpHeaders.locationHeader, flow.authorizationUrl.toString());
        request.response.headers.set(
            HttpHeaders.accessControlAllowOriginHeader, '*');
        await request.response.close();
      }
    } on Exception catch (error) {
      // Resolution/PAR failures carry operator-irrelevant detail for
      // the player; the operator surface is the node log, not this
      // body — so the failure is never silent there.
      stderr.writeln(
          'rooms-node: /auth/start failed for "$handle": $error');
      await _plainError(request, 400, 'invalid_request',
          'could not start sign-in for that handle');
    }
  }

  Future<void> _authCallback(
    HttpRequest request,
    AtprotoAuthProvider provider,
  ) async {
    AtprotoAuthFlow? flow;
    try {
      flow = await provider.complete(request.uri);
    } on Exception catch (error) {
      // Same operator surface as /auth/start: the exact exception goes
      // to the node log; the browser only ever sees a generic page.
      stderr.writeln('rooms-node: /auth/callback failed: $error');
      flow = null;
    }
    request.response.headers.contentType = ContentType.html;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.headers.set(
        HttpHeaders.accessControlAllowOriginHeader, '*');
    if (flow == null) {
      request.response.statusCode = 400;
      request.response.write('<!doctype html><meta charset="utf-8">'
          '<title>Sign-in</title><p>Unknown or expired sign-in. '
          'Start again from the application.</p>');
      await request.response.close();
      return;
    }
    if (flow.result != null) {
      final did = _htmlEscape(flow.result!['did'] as String? ?? '');
      request.response.statusCode = 200;
      request.response.write('<!doctype html><meta charset="utf-8">'
          '<title>Signed in</title><p>Signed in as <code>$did</code>. '
          'Return to the application to continue.</p>');
      await request.response.close();
      return;
    }
    // Terminal flow failure (exchange/iss/DPoP…): the browser page is
    // generic by design, so the reason lives in the node log — and in
    // the 410 body of /auth/result, which the panel surfaces.
    stderr.writeln('rooms-node: /auth/callback: sign-in failed '
        '(flow ${flow.id}): ${flow.error?['message']}');
    request.response.statusCode = 400;
    request.response.write('<!doctype html><meta charset="utf-8">'
        '<title>Sign-in failed</title><p>Sign-in failed. '
        'Return to the application and try again.</p>');
    await request.response.close();
  }

  static String _htmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  Future<bool> _plainErrorBool(
    HttpRequest request,
    int status,
    String code,
    String message,
  ) async {
    await _plainError(request, status, code, message);
    return true;
  }

  Future<void> _jsonNoStore(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    if (_closed) return;
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.headers.set(
        HttpHeaders.accessControlAllowOriginHeader, '*');
    request.response.write(jsonEncode(body));
    await request.response.close();
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

  Future<void> _plainError(
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

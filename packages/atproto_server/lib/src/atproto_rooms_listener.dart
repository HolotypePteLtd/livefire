import 'dart:convert';
import 'dart:io';

import 'package:server_sdk/server_sdk.dart';

import 'atproto/atproto_provider.dart';
import 'ident/guest_identity.dart';
import 'panel/panel_api.dart';

/// Serves the configured account and panel routes on the room listener's port.
class AtprotoRoomsListener extends RoomsListener {
  AtprotoRoomsListener({
    required super.supervisor,
    required super.api,
    required super.store,
    required super.tokens,
    required super.tokenLedger,
    required super.originGate,
    required super.throttle,
    super.onPeerAttached,
    super.trustedProxies,
    this.atproto,
    this.panel,
    this.ident,
  });

  /// The atproto auth provider (`docs/identity.md`); null when the node
  /// runs guest tokens only.
  final AtprotoAuthProvider? atproto;

  /// The developer panel (`panel/panel_api.dart`); null when the
  /// embedder does not serve one (then `/panel*` is a plain 404).
  final PanelApi? panel;

  /// The guest identity ladder (`ident/guest_identity.dart`); null when
  /// the node does not offer device accounts (then `/ident*` is a 404).
  final GuestIdentityApi? ident;

  @override
  Future<bool> handleAdditionalRequest(HttpRequest request) async {
    final path = request.uri.path;
    if (path == '/panel' || path.startsWith('/panel/')) {
      return await panel?.handle(request) ?? false;
    }
    if (path == '/ident' || path.startsWith('/ident/')) {
      return await ident?.handle(request) ?? false;
    }
    return _authRoutes(request);
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
          request,
          404,
          'not_found',
          'atproto auth disabled',
        );
      }
      await _jsonNoStore(request, 200, provider.clientMetadata());
      return true;
    }
    if (path == '/oauth/jwks.json' && request.method == 'GET') {
      if (provider == null) {
        return _plainErrorBool(
          request,
          404,
          'not_found',
          'atproto auth disabled',
        );
      }
      await _jsonNoStore(request, 200, provider.publicJwks());
      return true;
    }
    if (path == '/auth/start' && request.method == 'GET') {
      if (provider == null) {
        return _plainErrorBool(
          request,
          404,
          'not_found',
          'atproto auth disabled',
        );
      }
      await _authStart(request, provider);
      return true;
    }
    if (path == '/auth/callback' && request.method == 'GET') {
      if (provider == null) {
        return _plainErrorBool(
          request,
          404,
          'not_found',
          'atproto auth disabled',
        );
      }
      await _authCallback(request, provider);
      return true;
    }
    if (path == '/auth/result' && request.method == 'GET') {
      if (provider == null) {
        return _plainErrorBool(
          request,
          404,
          'not_found',
          'atproto auth disabled',
        );
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
      await writeError(request, 429, 'quota_exceeded', 'too many attempts');
      return;
    }
    final params = request.uri.queryParameters;
    final handle = (params['handle'] ?? '').trim();
    final roomKey = params['room'] ?? '';
    final creator = params['creator'] == 'true';
    final creatorProof = params['creatorToken'];
    if (handle.isEmpty || roomKey.isEmpty) {
      await writeError(
        request,
        400,
        'invalid_request',
        'handle and room are required',
      );
      return;
    }
    final stored = store.roomByKey(roomKey);
    if (supervisor.room(roomKey) == null) {
      if (stored == null || !stored.live) {
        await writeError(request, 404, 'not_found', 'unknown room');
        return;
      }
    }
    if (creator) {
      if (stored == null ||
          creatorProof == null ||
          creatorProof.isEmpty ||
          !secureEquals(creatorProof, stored.creatorToken)) {
        await writeError(
          request,
          403,
          'forbidden',
          'creatorToken is required to claim room leadership',
        );
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
          'expiresInMs': flow.expiresAt
              .difference(DateTime.now().toUtc())
              .inMilliseconds,
        });
      } else {
        request.response.statusCode = 302;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          flow.authorizationUrl.toString(),
        );
        request.response.headers.set(
          HttpHeaders.accessControlAllowOriginHeader,
          '*',
        );
        await request.response.close();
      }
    } on Exception catch (error) {
      // Resolution/PAR failures carry operator-irrelevant detail for
      // the player; the operator surface is the node log, not this
      // body — so the failure is never silent there.
      stderr.writeln('rooms-node: /auth/start failed for "$handle": $error');
      await writeError(
        request,
        400,
        'invalid_request',
        'could not start sign-in for that handle',
      );
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
      HttpHeaders.accessControlAllowOriginHeader,
      '*',
    );
    if (flow == null) {
      request.response.statusCode = 400;
      request.response.write(
        '<!doctype html><meta charset="utf-8">'
        '<title>Sign-in</title><p>Unknown or expired sign-in. '
        'Start again from the application.</p>',
      );
      await request.response.close();
      return;
    }
    if (flow.result != null) {
      final did = _htmlEscape(flow.result!['did'] as String? ?? '');
      request.response.statusCode = 200;
      request.response.write(
        '<!doctype html><meta charset="utf-8">'
        '<title>Signed in</title><p>Signed in as <code>$did</code>. '
        'Return to the application to continue.</p>',
      );
      await request.response.close();
      return;
    }
    // Terminal flow failure (exchange/iss/DPoP…): the browser page is
    // generic by design, so the reason lives in the node log — and in
    // the 410 body of /auth/result, which the panel surfaces.
    stderr.writeln(
      'rooms-node: /auth/callback: sign-in failed '
      '(flow ${flow.id}): ${flow.error?['message']}',
    );
    request.response.statusCode = 400;
    request.response.write(
      '<!doctype html><meta charset="utf-8">'
      '<title>Sign-in failed</title><p>Sign-in failed. '
      'Return to the application and try again.</p>',
    );
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
    await writeError(request, status, code, message);
    return true;
  }

  Future<void> _jsonNoStore(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    if (isClosed) return;
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.headers.set(
      HttpHeaders.accessControlAllowOriginHeader,
      '*',
    );
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

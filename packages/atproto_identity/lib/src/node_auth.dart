import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'account_models.dart';

/// A sign-in flow started on a rooms node (`/auth/start`).
final class NodeAuthFlow {
  const NodeAuthFlow({
    required this.flow,
    required this.authorizationUrl,
    required this.expiresAt,
  });
  final String flow;
  final Uri authorizationUrl;
  final DateTime expiresAt;
}

/// What the node handed back for a completed flow: a normal node join token
/// whose claim set includes the verified DID, plus (when requested) a
/// creator token.
final class NodeAuthCredential {
  const NodeAuthCredential({
    required this.joinToken,
    required this.joinTokenExpiresAt,
    required this.did,
    required this.roomKey,
    required this.url,
    this.handle,
    this.creatorToken,
  });
  final String joinToken;
  final DateTime joinTokenExpiresAt;
  final String did;
  final String? handle;

  /// The room the token opens, its full play URL and the optional
  /// leader-claim token (relay rooms).
  final String roomKey;
  final Uri url;
  final String? creatorToken;
}

/// Drives the rooms node's atproto auth endpoints from any Dart client
/// (web or desktop; no `dart:io` here).
///
/// Completion mechanism: **polling**. The node's `/auth/callback` stores the
/// result under the flow id; this helper polls `GET /auth/result?flow=…`
/// until it resolves. That is the one mechanism that works unchanged for
/// web games (open the authorization URL in a popup/redirect) and desktop
/// apps (open it in the system browser) — no loopback listener, no
/// postMessage, no custom URL scheme (mobile custom-scheme flows are a
/// deliberate TODO).
final class NodeAuthClient {
  NodeAuthClient({
    required this.nodeBaseUrl,
    http.Client? httpClient,
    this.pollInterval = const Duration(milliseconds: 300),
  }) : _http = httpClient ?? http.Client();

  /// The node's public origin, e.g. `https://rooms.example.com`.
  final Uri nodeBaseUrl;
  final http.Client _http;
  final Duration pollInterval;

  Map<String, String> _params(
    String handle,
    String room, {
    bool creator = false,
    String? creatorToken,
  }) => {
    'handle': handle,
    'room': room,
    if (creator) 'creator': 'true',
    if (creatorToken != null) 'creatorToken': creatorToken,
    'format': 'json',
  };

  /// Starts a flow: resolves nothing itself — the node does handle → PDS →
  /// authorization server and returns the URL to send the user's browser to.
  Future<NodeAuthFlow> start(
    String handle,
    String room, {
    bool creator = false,
    String? creatorToken,
  }) async {
    final uri = nodeBaseUrl.replace(
      path: '${nodeBaseUrl.path.replaceAll(RegExp(r'/$'), '')}/auth/start',
      queryParameters: _params(
        handle,
        room,
        creator: creator,
        creatorToken: creatorToken,
      ),
    );
    final response = await _http.get(uri);
    final body = _decode(response);
    if (response.statusCode != 200) {
      throw _error(response.statusCode, body, 'start failed');
    }
    final url = body['authorizationUrl'];
    final flow = body['flow'];
    final expiresIn = body['expiresInMs'];
    if (url is! String || flow is! String || expiresIn is! int) {
      throw const AtprotoException(AtprotoError.invalidData, 'Bad start');
    }
    return NodeAuthFlow(
      flow: flow,
      authorizationUrl: Uri.parse(url),
      expiresAt: DateTime.now().toUtc().add(Duration(milliseconds: expiresIn)),
    );
  }

  /// One poll. Returns the credential when the flow completed, null while
  /// it is still pending; throws when the node reports a terminal failure.
  Future<NodeAuthCredential?> poll(String flow) async {
    final uri = nodeBaseUrl.replace(
      path: '${nodeBaseUrl.path.replaceAll(RegExp(r'/$'), '')}/auth/result',
      queryParameters: {'flow': flow},
    );
    final response = await _http.get(uri);
    final body = _decode(response);
    final status = body['status'];
    if (status == 'pending') return null;
    if (status == 'error' || response.statusCode == 410) {
      throw _error(response.statusCode, body, 'sign-in failed');
    }
    if (response.statusCode != 200 || status != 'ok') {
      throw _error(response.statusCode, body, 'unexpected result');
    }
    return NodeAuthCredential(
      joinToken: body['joinToken'] as String,
      joinTokenExpiresAt: DateTime.parse(body['joinTokenExpiresAt'] as String),
      did: body['did'] as String,
      handle: body['handle'] as String?,
      roomKey: body['roomKey'] as String,
      url: Uri.parse(body['url'] as String),
      creatorToken: body['creatorToken'] as String?,
    );
  }

  /// Start + open the browser (injected so web and desktop differ only
  /// here) + poll until the node has the result.
  Future<NodeAuthCredential> signIn(
    String handle,
    String room, {
    bool creator = false,
    String? creatorToken,
    required Future<bool> Function(Uri url) openBrowser,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final flow = await start(
      handle,
      room,
      creator: creator,
      creatorToken: creatorToken,
    );
    if (!await openBrowser(flow.authorizationUrl)) {
      throw const AtprotoException(
        AtprotoError.unavailable,
        'Could not open your browser. Please try again.',
      );
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final credential = await poll(flow.flow);
      if (credential != null) return credential;
      await Future<void>.delayed(pollInterval);
    }
    throw const AtprotoException(
      AtprotoError.cancelled,
      'Sign-in timed out. Please try again.',
    );
  }

  Map<String, dynamic> _decode(http.Response response) {
    try {
      return (response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>);
    } on FormatException {
      throw const AtprotoException(AtprotoError.invalidData, 'Bad response');
    }
  }

  AtprotoException _error(int status, Map<String, dynamic> body, String what) {
    final error = body['error'];
    final message = error is Map && error['message'] is String
        ? error['message'] as String
        : what;
    return AtprotoException(
      status >= 500 ? AtprotoError.unavailable : AtprotoError.networkFailure,
      message,
    );
  }
}

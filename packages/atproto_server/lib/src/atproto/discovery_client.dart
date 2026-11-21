import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The protected-resource discovery hop with a self-host fallback.
///
/// The atproto OAuth discovery chain the node implements:
///
/// 1. handle → DID (entryway XRPC, `atproto_resolver.dart`),
/// 2. DID document → PDS service endpoint,
/// 3. `GET <PDS>/.well-known/oauth-protected-resource` (RFC 9728) → the
///    real authorization server is `authorization_servers[0]`,
/// 4. `GET <AS>/.well-known/oauth-authorization-server` (RFC 8414),
/// 5. PAR at the AS → authorization URL.
///
/// Sharded PDS hosts (Bluesky's `*.host.bsky.network`) are OAuth
/// **resource** servers: they 404 `/.well-known/oauth-authorization-server`
/// and publish the actual AS — `https://bsky.social` — only in their
/// protected-resource document. Single-server (self-hosted) deployments
/// often publish no protected-resource document at all because they ARE
/// their own authorization server.
///
/// The pinned `atproto_oauth` client (0.8.3 — the latest on pub) performs
/// step 3 but treats a missing or unusable document as fatal, which
/// breaks the self-host topology. This client sits under the provider's
/// HTTP stack ([AtprotoAuthProvider] wires it around its inner client)
/// and closes that gap without forking the library's PAR/PKCE/DPoP
/// machinery: a GET of the protected-resource path passes through
/// **verbatim** when the upstream document is usable (the library then
/// validates the entry itself: https, bare origin, non-reserved host),
/// and is answered locally with
/// `{"authorization_servers": ["<that origin>"]}` when the server 404s,
/// errors or publishes garbage — the PDS-as-AS fallback, which is what
/// step 4 then discovers metadata for. Every other request (AS
/// metadata GETs, the confidential client's signed PAR/token POSTs)
/// flows through untouched.
final class DiscoveryClient extends http.BaseClient {
  DiscoveryClient(this._inner);

  final http.Client _inner;

  /// The RFC 9728 well-known path the hop requests.
  static const String protectedResourcePath =
      '/.well-known/oauth-protected-resource';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    final scheme = request.url.scheme;
    if (request.method != 'GET' ||
        request.url.path != protectedResourcePath ||
        (scheme != 'http' && scheme != 'https')) {
      return response;
    }
    final materialized = await http.Response.fromStream(response);
    if (_usableDocument(materialized.body)) {
      return _replay(materialized);
    }
    return _selfHostFallback(request.url);
  }

  /// Whether [body] is a protected-resource document the hop can use:
  /// a JSON object whose `authorization_servers` is a non-empty list
  /// whose first entry is an absolute URI string.
  static bool _usableDocument(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) return false;
      final servers = json['authorization_servers'];
      if (servers is! List || servers.isEmpty) return false;
      final first = servers.first;
      if (first is! String || first.trim().isEmpty) return false;
      final uri = Uri.tryParse(first.trim());
      return uri != null && uri.isAbsolute;
    } on FormatException {
      return false;
    }
  }

  /// Re-serves [response] with its (already read) body, preserving the
  /// status and headers the upstream sent.
  static http.StreamedResponse _replay(http.Response response) =>
      http.StreamedResponse(
        http.ByteStream.fromBytes(response.bodyBytes),
        response.statusCode,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );

  /// The fallback answer for a PDS at [url]: it is its own authorization
  /// server. The origin keeps whatever scheme the PDS was reached over
  /// (http only passes the library's checks with private networks
  /// allowed — i.e. in tests and local development).
  static http.StreamedResponse _selfHostFallback(Uri url) {
    final origin = url.origin;
    final body = utf8.encode(
      jsonEncode({
        'resource': origin,
        'authorization_servers': [origin],
      }),
    );
    return http.StreamedResponse(
      http.ByteStream.fromBytes(body),
      200,
      headers: {
        'content-type': 'application/json',
        'content-length': '${body.length}',
      },
    );
  }

  @override
  void close() => _inner.close();
}

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'client_keys.dart';

/// An [http.Client] wrapper that turns the OAuth client's form POSTs to
/// the authorization server — **both** the pushed authorization request
/// and the token endpoint (authorization-code and refresh grants) —
/// into **confidential client** requests by appending RFC 7523
/// `private_key_jwt` parameters, signed with the node's ES256 key.
///
/// The atproto OAuth profile requires web clients to authenticate at
/// PAR and the token endpoint (live-confirmed against bsky.social: PAR
/// without a `client_assertion` is rejected with `invalid_request`);
/// `atproto_oauth` itself speaks only for public (native) clients, so
/// the node layers client authentication on top without forking the
/// library's PKCE/DPoP/PAR machinery.
///
/// The assertion's `aud` is the origin of the endpoint being called,
/// which `atproto_oauth` guarantees equals the authorization server's
/// **issuer**: it validates RFC 8414 §3.3 that the discovered issuer
/// matches the AS origin, and that the PAR/token endpoints are
/// same-origin https URLs of that issuer. Authorization servers that
/// require `aud` = issuer (bsky.social among them) therefore accept it.
final class ConfidentialClient extends http.BaseClient {
  ConfidentialClient({
    required this._keys,
    required this._clientId,
    required this._inner,
  });

  static const assertionType =
      'urn:ietf:params:oauth:client-assertion-type:jwt-bearer';

  final NodeClientKeys _keys;
  final String _clientId;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request &&
        request.method == 'POST' &&
        !_requestIsAuthenticated(request) &&
        // The token endpoint (any grant) carries grant_type=; the pushed
        // authorization request carries code_challenge= (the library
        // always sends PKCE with PAR). No other form POST leaves the
        // OAuth client.
        (request.body.contains('grant_type=') ||
            request.body.contains('code_challenge='))) {
      final audience = request.url.origin;
      final assertion = _keys.clientAssertion(
        clientId: _clientId,
        audience: audience,
      );
      request.bodyFields = {
        ...request.bodyFields,
        'client_assertion_type': assertionType,
        'client_assertion': assertion,
      };
    }
    return _inner.send(request);
  }

  static bool _requestIsAuthenticated(http.Request request) =>
      request.body.contains('client_assertion=');

  @override
  void close() => _inner.close();
}

/// Decodes and validates a client assertion the way an authorization
/// server must (used by the in-test fake AS; exported for reuse).
Map<String, String> decodeClientAssertion(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) throw const FormatException('not a JWS');
  Map<String, dynamic> decode(String part) =>
      jsonDecode(utf8.decode(base64Url.decode(part))) as Map<String, dynamic>;
  return {
    'header': jsonEncode(decode(parts[0])),
    'payload': jsonEncode(decode(parts[1])),
    'signature': parts[2],
  };
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io_client;
import 'package:pointycastle/export.dart';

// Shared by atproto_test.dart and panel_test.dart: the fake AT Protocol
// world (extracted verbatim from its original home in atproto_test.dart).
/// An in-test AT Protocol world — entryway + PLC directory + PDS +
/// authorization server on ONE real-TLS origin (atproto_oauth hardcodes
/// https for AS discovery/PAR/token). Implements exactly the endpoints the
/// node calls; everything the "user" does is automatic approval.
///
/// Real-world differences, kept honest:
/// - No consent screen; the authorize endpoint approves immediately.
/// - No DPoP proof verification (its presence is recorded, not checked).
/// - client_id is accepted over http (production AS reject non-https
///   client metadata URLs); the assertion SIGNATURE is fully verified
///   against the node's served JWKS, as is PKCE.
/// - No token/refresh rotation bookkeeping beyond the flow's needs.
class FakeAtprotoWorld {
  final identities = <String, String>{}; // handle -> did
  final profiles = <String, Map<String, dynamic>>{}; // did -> profile
  final problems = <String>[];
  final parForms = <String, Map<String, String>>{};
  final tokenCalls = <Map<String, String>>[];
  final _codes = <String, String>{};
  final _codePar = <String, Map<String, String>>{};
  final _refreshTokens = <String, String>{};
  Map<String, dynamic>? clientMetadata;
  Map<String, dynamic>? clientJwks;

  /// Set false to model a single-server (self-hosted) deployment that
  /// publishes NO protected-resource document — the discovery fallback
  /// path (the PDS is its own authorization server).
  bool serveProtectedResource = true;

  /// Every request path served, for discovery-order assertions.
  final requestedPaths = <String>[];

  HttpServer? _server;
  Directory? _certDir;
  http.Client? _client;

  String get origin => 'https://127.0.0.1:${_server!.port}';

  http.Client newClient() => _trustedClient();
  http.Client get client => _client ??= _trustedClient();

  http.Client _trustedClient() => io_client.IOClient(
        HttpClient()
          ..badCertificateCallback =
              (X509Certificate cert, String host, int port) =>
                  host == '127.0.0.1',
      );

  void addIdentity(String handle, String did,
      {String? displayName, String? avatar}) {
    identities[handle] = did;
    profiles[did] = {
      'did': did,
      'handle': handle,
      'displayName': ?displayName,
      'avatar': ?avatar,
    };
  }

  Future<void> start() async {
    final certDir = _certDir =
        await Directory.systemTemp.createTemp('fake-atproto-world-');
    final cert = '${certDir.path}/cert.pem';
    final key = '${certDir.path}/key.pem';
    final generated = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
      '-keyout', key, '-out', cert, '-days', '2', '-nodes',
      '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
    ]);
    if (generated.exitCode != 0) {
      throw StateError('openssl failed: ${generated.stderr}');
    }
    final context = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    final server = _server = await HttpServer.bindSecure(
      '127.0.0.1',
      0,
      context,
    );
    server.listen((request) => unawaited(_handle(request)));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _client?.close();
    _client = null;
    try {
      await _certDir?.delete(recursive: true);
    } catch (_) {}
    _certDir = null;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      requestedPaths.add('${request.method} $path');
      if (path == '/xrpc/com.atproto.identity.resolveHandle' &&
          request.method == 'GET') {
        final handle = request.uri.queryParameters['handle'];
        final did = handle == null ? null : identities[handle];
        if (did == null) {
          await _json(request, 400, {'error': 'invalid_request'});
        } else {
          await _json(request, 200, {'did': did});
        }
        return;
      }
      if (path.startsWith('/did:') && request.method == 'GET') {
        await _json(request, 200, {
          '@context': ['https://www.w3.org/ns/did/v1'],
          'id': path.substring('/did/'.length),
          'alsoKnownAs': ['at://ignored'],
          'service': [
            {
              'id': '#atproto_pds',
              'type': 'AtprotoPersonalDataServer',
              'serviceEndpoint': origin,
            },
          ],
        });
        return;
      }
      if (path == '/xrpc/app.bsky.actor.getProfile' &&
          request.method == 'GET') {
        final actor = request.uri.queryParameters['actor'];
        final profile = actor == null ? null : profiles[actor];
        if (profile == null) {
          await _json(request, 400, {'error': 'invalid_request'});
        } else {
          await _json(request, 200, profile);
        }
        return;
      }
      if (path == '/.well-known/oauth-protected-resource' &&
          request.method == 'GET') {
        if (!serveProtectedResource) {
          await _json(request, 404, {'error': 'NotFound'});
          return;
        }
        await _json(request, 200, {
          'authorization_servers': [origin],
        });
        return;
      }
      if (path == '/.well-known/oauth-authorization-server' &&
          request.method == 'GET') {
        await _json(request, 200, {
          'issuer': origin,
          'authorization_endpoint': '$origin/oauth/authorize',
          'pushed_authorization_request_endpoint': '$origin/oauth/par',
          'token_endpoint': '$origin/oauth/token',
        });
        return;
      }
      if (path == '/oauth/par' && request.method == 'POST') {
        final form = await _form(request);
        await _loadClientMetadata(form['client_id'] ?? '', form['redirect_uri'] ?? '');
        if (clientMetadata == null) {
          await _json(request, 400, {'error': 'invalid_client_metadata'});
          return;
        }
        // The real AS (bsky.social) rejects PAR without a valid
        // private_key_jwt client assertion — live-confirmed — so the
        // fixture enforces it here too.
        if (form['client_assertion_type'] != assertionType ||
            !verifyClientAssertion(form['client_assertion'] ?? '',
                where: 'par')) {
          await _json(request, 401, {'error': 'invalid_client'});
          return;
        }
        final uri = 'par_${parForms.length + 1}';
        parForms[uri] = form;
        await _json(request, 201, {'request_uri': uri, 'expires_in': 300});
        return;
      }
      if (path == '/oauth/authorize' && request.method == 'GET') {
        final par = parForms[request.uri.queryParameters['request_uri']];
        if (par == null) {
          await _json(request, 400, {'error': 'invalid_request_uri'});
          return;
        }
        final did = identities[par['login_hint']] ??
            identities.values.first;
        final code = 'code_${_codes.length + 1}';
        _codes[code] = did;
        _codePar[code] = par;
        final redirect = Uri.parse(par['redirect_uri']!).replace(
          queryParameters: {
            'code': code,
            'state': par['state']!,
            'iss': origin,
          },
        );
        request.response.statusCode = 302;
        request.response.headers
            .set(HttpHeaders.locationHeader, '$redirect');
        await request.response.close();
        return;
      }
      if (path == '/oauth/token' && request.method == 'POST') {
        final form = await _form(request);
        tokenCalls.add(form);
        final dpop = request.headers.value('DPoP');
        if (dpop == null || dpop.isEmpty) {
          problems.add('token: missing DPoP proof');
        }
        if (form['client_assertion_type'] != assertionType) {
          problems.add('token: missing client assertion type');
          await _json(request, 401, {'error': 'invalid_client'});
          return;
        }
        if (!verifyClientAssertion(form['client_assertion'] ?? '')) {
          await _json(request, 401, {'error': 'invalid_client'});
          return;
        }
        String? did;
        if (form['grant_type'] == 'authorization_code') {
          did = _codes[form['code']];
          if (did != null && !_verifyPkce(form)) did = null;
        } else if (form['grant_type'] == 'refresh_token') {
          did = _refreshTokens[form['refresh_token']];
        }
        if (did == null) {
          await _json(request, 400, {'error': 'invalid_grant'});
          return;
        }
        final refresh = 'rt_${tokenCalls.length}';
        _refreshTokens[refresh] = did;
        await _json(request, 200, {
          'access_token': 'at_${tokenCalls.length}',
          'token_type': 'DPoP',
          'scope': 'atproto',
          'sub': did,
          'expires_in': 3600,
          'refresh_token': refresh,
        });
        return;
      }
      await _json(request, 404, {'error': 'not_found'});
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  bool _verifyPkce(Map<String, String> form) {
    // The PAR that issued this code carried S256(code_verifier); the
    // token request carries the verifier itself.
    final challenge = _codePar[form['code']]?['code_challenge'];
    if (challenge == null) return true; // PAR didn't record one
    final verifier = form['code_verifier'];
    if (verifier == null) {
      problems.add('token: missing code_verifier');
      return false;
    }
    // RFC 7636: the verifier is unreserved characters (hash its UTF-8
    // bytes); the challenge is base64url(SHA-256(verifier)).
    final computed =
        crypto.sha256.convert(utf8.encode(verifier)).bytes;
    final expected = _b64decode(challenge);
    var ok = computed.length == expected.length;
    for (var i = 0; ok && i < computed.length; i++) {
      if (computed[i] != expected[i]) ok = false;
    }
    if (!ok) problems.add('token: PKCE mismatch');
    return ok;
  }

  /// Fetches the client metadata document (like a real AS) and validates
  /// the PAR's client_id/redirect_uri against it; records the JWKS.
  Future<void> _loadClientMetadata(String clientId, String redirectUri) async {
    if (clientMetadata != null) return;
    try {
      final response = await client.get(Uri.parse(clientId));
      if (response.statusCode != 200) return;
      final metadata = jsonDecode(response.body) as Map<String, dynamic>;
      if (metadata['client_id'] != clientId) return;
      if (metadata['token_endpoint_auth_method'] != 'private_key_jwt') {
        problems.add('client metadata: not a confidential client');
        return;
      }
      final redirectUris = metadata['redirect_uris'];
      if (redirectUris is! List || !redirectUris.contains(redirectUri)) {
        problems.add('client metadata: redirect_uri not registered');
        return;
      }
      clientMetadata = metadata;
      final jwksUri = metadata['jwks_uri'];
      if (jwksUri is String) {
        final jwksResponse = await client.get(Uri.parse(jwksUri));
        if (jwksResponse.statusCode == 200) {
          clientJwks = jsonDecode(jwksResponse.body) as Map<String, dynamic>;
        }
      }
    } catch (_) {
      // Leave clientMetadata null: the PAR is rejected.
    }
  }

  /// The `private_key_jwt` constant the fixture enforces.
  static const assertionType =
      'urn:ietf:params:oauth:client-assertion-type:jwt-bearer';

  /// Verifies a client assertion the way the real AS must: JWS shape,
  /// ES256 header, `kid` present in the served JWKS, iss/sub = the
  /// registered client_id, aud = THIS origin (the AS issuer), a sane
  /// iat/exp window, and the ECDSA signature over the signing input.
  /// Rejections are recorded in [problems] tagged with [where].
  bool verifyClientAssertion(String assertion, {String where = 'token'}) {
    if (assertion.isEmpty) {
      problems.add('$where: missing client assertion');
      return false;
    }
    if (clientMetadata == null) {
      problems.add('$where: no client metadata on record');
      return false;
    }
    final keys = (clientJwks?['keys'] as List?) ?? const [];
    if (keys.isEmpty) {
      problems.add('$where: no client JWKS on record');
      return false;
    }
    final parts = assertion.split('.');
    if (parts.length != 3) {
      problems.add('$where: assertion is not a JWS');
      return false;
    }
    Map<String, dynamic> decode(String part) =>
        jsonDecode(utf8.decode(_b64decode(part))) as Map<String, dynamic>;
    final Map<String, dynamic> header;
    final Map<String, dynamic> payload;
    try {
      header = decode(parts[0]);
      payload = decode(parts[1]);
    } on FormatException {
      problems.add('$where: assertion is not valid JSON');
      return false;
    }
    if (header['alg'] != 'ES256') {
      problems.add('$where: assertion alg is not ES256');
      return false;
    }
    final key = keys.where((k) =>
        k is Map && (k['kid'] == header['kid'] ||
            (header['kid'] == null && k['kid'] == null))).firstOrNull;
    if (key == null) {
      problems.add('$where: assertion kid not in JWKS');
      return false;
    }
    if (payload['iss'] != clientMetadata!['client_id'] ||
        payload['sub'] != clientMetadata!['client_id']) {
      problems.add('$where: assertion iss/sub is not the client_id');
      return false;
    }
    if (payload['aud'] != origin) {
      problems.add('$where: assertion aud is not the AS issuer');
      return false;
    }
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    if (payload['iat'] is! int ||
        payload['exp'] is! int ||
        payload['iat'] as int > now + 60 ||
        payload['exp'] as int < now) {
      problems.add('$where: assertion time window invalid');
      return false;
    }
    // ES256 verify against the JWKS public point.
    final signature = _b64decode(parts[2]);
    if (signature.length != 64) {
      problems.add('$where: raw signature is not 64 bytes');
      return false;
    }
    final domain = ECDomainParameters('secp256r1');
    List<int> coord(String name) =>
        _b64decode((key as Map)[name] as String);
    final pointBytes = Uint8List(65);
    pointBytes[0] = 4;
    pointBytes.setAll(1, coord('x'));
    pointBytes.setAll(33, coord('y'));
    final point = domain.curve.decodePoint(pointBytes);
    if (point == null) {
      problems.add('$where: JWKS point is off-curve');
      return false;
    }
    final verifier = Signer('SHA-256/ECDSA')
      ..init(
        false,
        PublicKeyParameter<ECPublicKey>(ECPublicKey(point, domain)),
      );
    return verifier.verifySignature(
      utf8.encode('${parts[0]}.${parts[1]}'),
      ECSignature(_bigInt(signature.sublist(0, 32)),
          _bigInt(signature.sublist(32))),
    );
  }

  Future<Map<String, String>> _form(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    return Uri.splitQueryString(body);
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

/// Tolerant base64url decode: strip existing padding, normalize the
/// alphabet, re-pad to a multiple of four.
List<int> _b64decode(String value) {
  var text = value.replaceAll('=', '');
  if (text.length % 4 == 1) throw FormatException('bad base64url: $value');
  text = text.replaceAll('-', '+').replaceAll('_', '/');
  return base64.decode(text.padRight((text.length + 3) & ~3, '='));
}

BigInt _bigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

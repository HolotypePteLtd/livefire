import 'dart:convert';

import 'package:atproto_identity/atproto_identity.dart'
    show
        handleInvalid,
        IdentityException; // same declarations atproto_oauth re-exports
import 'package:atproto_oauth/atproto_oauth.dart';
import 'package:http/http.dart' as http;

import 'did_web_client.dart';

/// Node-side identity resolution: handle → DID (via the entryway's
/// `com.atproto.identity.resolveHandle`) and DID → PDS (via the PLC
/// directory for `did:plc`, `/.well-known/did.json` for `did:web`).
///
/// Both base URLs come from configuration so tests can point them at a
/// local fake; production defaults are `https://bsky.social` and
/// `https://plc.directory`.
///
/// Real-world differences from the canonical resolver
/// (`HttpIdentityResolver` in `atproto_identity`), kept deliberate:
/// - Handles resolve through the entryway XRPC instead of DNS TXT /
///   `/.well-known/atproto-did` — one request, one config knob. A handle
///   the entryway does not know is rejected.
/// - No bidirectional handle verification (DID document `alsoKnownAs` is
///   not checked back): the node only needs the DID and its PDS here.
class NodeAtprotoResolver implements IdentityResolver {
  NodeAtprotoResolver({
    required this.entrywayUrl,
    required this.plcDirectoryUrl,
    // Used for configured endpoints and local did:web fixtures.
    http.Client? httpClient,
    this.allowPrivateNetwork = false,
  }) : _http = httpClient ?? http.Client();

  /// Entryway origin for `com.atproto.identity.resolveHandle`.
  final String entrywayUrl;

  /// PLC directory origin for `did:plc` document lookups.
  final String plcDirectoryUrl;
  final bool allowPrivateNetwork;
  final http.Client _http;

  @override
  Future<ResolvedIdentity> resolve(String input) async {
    final value = input.trim().replaceFirst(RegExp(r'^@'), '');
    final did = value.startsWith('did:') ? value : await _resolveHandle(value);
    final pds = await _resolveDidDocument(did);
    return ResolvedIdentity(
      did: did,
      pds: pds,
      // The supplied handle is what the user typed; when resolving from a
      // DID there is no verified handle on this path.
      handle: value.startsWith('did:') ? handleInvalid : value,
    );
  }

  Future<String> _resolveHandle(String handle) async {
    final uri = Uri.parse(
      '$entrywayUrl/xrpc/com.atproto.identity.resolveHandle',
    ).replace(queryParameters: {'handle': handle});
    final response = await _http.get(uri);
    if (response.statusCode != 200) {
      throw IdentityException('Could not resolve handle "$handle"');
    }
    final did = (jsonDecode(response.body) as Map<String, dynamic>)['did'];
    if (did is! String || !did.startsWith('did:')) {
      throw IdentityException('Invalid DID for handle "$handle"');
    }
    return did;
  }

  static final _plcDidPattern = RegExp(r'^did:plc:[a-z2-7]+$');

  Future<String> _resolveDidDocument(String did) async {
    final Uri uri;
    if (did.startsWith('did:plc:')) {
      if (!_plcDidPattern.hasMatch(did)) {
        throw IdentityException('Invalid did:plc syntax in "$did"');
      }
      uri = Uri.parse('$plcDirectoryUrl/$did');
    } else if (did.startsWith('did:web:')) {
      final rawMethodSpecific = did.substring('did:web:'.length);
      if (rawMethodSpecific.contains('/') ||
          rawMethodSpecific.contains('@') ||
          rawMethodSpecific.contains('?') ||
          rawMethodSpecific.contains('#')) {
        throw IdentityException('Invalid did:web syntax in "$did"');
      }
      final firstSegment = rawMethodSpecific.split(':').first;
      final decodedAuthority = Uri.decodeComponent(firstSegment);
      final parsedAuthority = Uri.tryParse('https://$decodedAuthority');
      if (parsedAuthority == null ||
          parsedAuthority.host.isEmpty ||
          parsedAuthority.userInfo.isNotEmpty ||
          parsedAuthority.path.isNotEmpty ||
          parsedAuthority.hasQuery ||
          parsedAuthority.hasFragment) {
        throw IdentityException('Invalid did:web host in "$did"');
      }
      final scheme = allowPrivateNetwork ? 'http' : 'https';
      uri = Uri(
        scheme: scheme,
        host: parsedAuthority.host,
        port: parsedAuthority.hasPort ? parsedAuthority.port : null,
        path: '/.well-known/did.json',
      );
    } else {
      throw IdentityException('Unsupported DID method in "$did"');
    }
    final http.Response response;
    if (!allowPrivateNetwork && did.startsWith('did:web:')) {
      final client = DidWebClient();
      try {
        response = await client.get(uri);
      } finally {
        client.close();
      }
    } else {
      response = await _http.get(uri);
    }
    if (response.statusCode != 200) {
      throw IdentityException('Could not resolve DID document for "$did"');
    }
    final document = jsonDecode(response.body) as Map<String, dynamic>;
    final services = document['service'];
    if (services is List) {
      for (final service in services) {
        if (service is Map &&
            service['type'] == 'AtprotoPersonalDataServer' &&
            service['serviceEndpoint'] is String) {
          var endpoint = service['serviceEndpoint'] as String;
          if (endpoint.endsWith('/')) {
            endpoint = endpoint.substring(0, endpoint.length - 1);
          }
          return endpoint;
        }
      }
    }
    throw IdentityException('DID document for "$did" has no PDS service');
  }
}

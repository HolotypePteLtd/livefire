import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

import 'atproto_world.dart';

/// Discovery tests for the atproto sign-in chain: the
/// `/.well-known/oauth-protected-resource` hop (the live bug: sharded
/// Bluesky PDS hosts 404 `/.well-known/oauth-authorization-server` and
/// publish the real AS — bsky.social — only in their
/// protected-resource document) and the self-host fallback (a PDS with
/// no such document is its own AS).
///
/// Topologies covered:
/// - **sharded** (`_ShardedPds` + FakeAtprotoWorld as the AS): the PDS
///   serves identity + the protected-resource doc pointing at a SECOND
///   host (the AS) and 404s the AS-metadata path; sign-in must complete
///   with PAR and authorize at the AS host.
/// - **self-host** (FakeAtprotoWorld alone, `serveProtectedResource =
///   false`): nothing serves the hop; the fallback answers PDS-as-AS
///   and sign-in must still complete.
/// - **unit** (plain HTTP fixtures): DiscoveryClient passes a usable
///   document through verbatim and synthesizes the PDS origin on 404,
///   error status, garbage and empty documents.
/// - **live** (optional): the real network chain for hydroxide.dev,
///   skipped when offline.
Future<void> main() async {
  // Decided BEFORE the groups are declared: `skip:` is evaluated when
  // the test is registered, so a setUpAll probe would always see the
  // initial value.
  var online = false;
  try {
    final probe = await http
        .get(Uri.parse(
            'https://bsky.social/.well-known/oauth-authorization-server'))
        .timeout(const Duration(seconds: 3));
    online = probe.statusCode >= 200 && probe.statusCode < 500;
  } on Object {
    online = false;
  }

  final world = FakeAtprotoWorld();
  setUpAll(() async {
    await world.start();
    world.addIdentity('hydroxide.bsky.social', 'did:plc:hydroxide');
  });
  tearDownAll(() => world.stop());
  setUp(() {
    // Each node generates fresh OAuth client keys; the fake AS caches
    // the client metadata it saw on the first PAR, so rediscover per test.
    world.clientMetadata = null;
    world.clientJwks = null;
    world.serveProtectedResource = true;
    world.requestedPaths.clear();
  });

  group('DiscoveryClient (the hop + fallback, unit level)', () {
    test('a usable protected-resource document passes through verbatim',
        () async {
      final server = await _JsonFixture.start({
        '/.well-known/oauth-protected-resource': (request) => _respond(
            request,
            200,
            {
              'resource': 'https://pds.example',
              'authorization_servers': ['https://as.example'],
            },
            extraHeaders: {'x-fixture': 'kept'}),
      });
      addTearDown(server.stop);

      final client = DiscoveryClient(http.Client());
      addTearDown(client.close);
      final response = await client.get(Uri.parse(
          '${server.origin}/.well-known/oauth-protected-resource'));
      expect(response.statusCode, 200);
      expect(response.headers['x-fixture'], 'kept'); // verbatim, not rebuilt
      expect((jsonDecode(response.body) as Map<String, dynamic>)['resource'],
          'https://pds.example');
    });

    for (final (name, status, body) in [
      ('404', 404, '{"error":"NotFound"}'),
      ('server error', 503, 'bad gateway html'),
      ('garbage', 200, 'not json at all'),
      ('empty array', 200, '{"authorization_servers":[]}'),
      ('non-absolute entry', 200, '{"authorization_servers":["as.example"]}'),
    ]) {
      test('a $status/$name document falls back to the PDS as its own AS',
          () async {
        final server = await _JsonFixture.start({
          '/.well-known/oauth-protected-resource': (request) =>
              _respond(request, status, body, raw: true),
        });
        addTearDown(server.stop);

        final client = DiscoveryClient(http.Client());
        addTearDown(client.close);
        final response = await client.get(Uri.parse(
            '${server.origin}/.well-known/oauth-protected-resource'));
        expect(response.statusCode, 200);
        expect(response.headers['content-type'], startsWith('application/json'));
        final doc = jsonDecode(response.body) as Map<String, dynamic>;
        expect(doc['authorization_servers'], [server.origin]);
        expect(doc['resource'], server.origin);
      });
    }

    test('other paths are never touched', () async {
      final server = await _JsonFixture.start({
        '/.well-known/oauth-authorization-server': (request) =>
            _respond(request, 200, {'issuer': 'https://as.example'}),
      });
      addTearDown(server.stop);
      final client = DiscoveryClient(http.Client());
      addTearDown(client.close);
      // A 404 on the AS-metadata path stays a 404 — the fallback applies
      // to the protected-resource hop only.
      final asPath = await client.get(Uri.parse(
          '${server.origin}/.well-known/oauth-authorization-server'));
      expect(asPath.statusCode, 200);
      final missing = await client.get(Uri.parse(
          '${server.origin}/.well-known/oauth-authorization-serverx'));
      expect(missing.statusCode, 404);
    });
  });

  group('sign-in discovery (whole chain, real fixture hosts)', () {
    test('sharded PDS: the hop finds the AS on a second host', () async {
      // The real Bluesky shape: the PDS hosts identity and the
      // protected-resource document ONLY; the AS (bsky.social stand-in:
      // the FakeAtprotoWorld) serves metadata, PAR, authorize and token.
      final pds = await _ShardedPds.start(
          identities: {'hydroxide.bsky.social': 'did:plc:hydroxide'},
          authorizationServers: [world.origin]);
      addTearDown(pds.stop);

      final node = await _DiscoveryNode.start(
          identityBase: pds.origin, httpClientFactory: world.newClient);
      addTearDown(node.stop);

      final result = await _signIn(node, 'hydroxide.bsky.social',
          client: world.client);

      // The authorization URL is on the AS host, not the PDS.
      expect(Uri.parse(result['authorizationUrl'] as String).origin,
          world.origin);

      // The PDS saw the hop — and only identity traffic: no PAR, no AS
      // metadata (it would 404 both, the live bug).
      expect(
          pds.requestedPaths, contains('GET /.well-known/oauth-protected-resource'));
      expect(pds.requestedPaths.where((p) => p.contains('/oauth/')), isEmpty);

      // The AS served metadata + PAR + authorize + token.
      expect(world.requestedPaths,
          contains('GET /.well-known/oauth-authorization-server'));
      expect(world.requestedPaths, contains('POST /oauth/par'));
      expect(world.requestedPaths, contains('GET /oauth/authorize'));

      // And the completed flow minted a DID-bearing join token.
      expect(result['joinToken'] as String, startsWith('jt_'));
      expect(result['did'], 'did:plc:hydroxide');
    });

    test('self-hosted PDS with no protected-resource doc falls back to itself',
        () async {
      world.serveProtectedResource = false; // the hop 404s
      final node = await _DiscoveryNode.start(
          identityBase: world.origin, httpClientFactory: world.newClient);
      addTearDown(node.stop);

      final result = await _signIn(node, 'hydroxide.bsky.social',
          client: world.client);

      // The hop WAS attempted (and 404'd) before the fallback kicked in…
      expect(world.requestedPaths,
          contains('GET /.well-known/oauth-protected-resource'));
      // …and the same origin then served AS metadata and PAR.
      expect(world.requestedPaths,
          contains('GET /.well-known/oauth-authorization-server'));
      expect(world.requestedPaths, contains('POST /oauth/par'));
      expect(Uri.parse(result['authorizationUrl'] as String).origin,
          world.origin);
      expect(result['joinToken'] as String, startsWith('jt_'));
    });
  });

  group('live discovery (optional)', () {
    test('hydroxide.dev resolves through the real chain to bsky.social',
        skip: online ? false : 'offline', () async {
      final resolver = NodeAtprotoResolver(
        entrywayUrl: 'https://bsky.social',
        plcDirectoryUrl: 'https://plc.directory',
      );
      final identity = await resolver.resolve('hydroxide.dev');
      expect(identity.did, startsWith('did:plc:'));

      // Step 3 — the hop — through the node's own client stack.
      final discovery = DiscoveryClient(http.Client());
      addTearDown(discovery.close);
      final response = await discovery.get(Uri.parse(
          '${identity.pds}/.well-known/oauth-protected-resource'));
      expect(response.statusCode, 200);
      final doc = jsonDecode(response.body) as Map<String, dynamic>;
      expect(doc['authorization_servers'], ['https://bsky.social']);

      // Step 4 — AS metadata at the resolved AS.
      final metadata = await http.get(Uri.parse(
          'https://bsky.social/.well-known/oauth-authorization-server'));
      expect(metadata.statusCode, 200);
      expect(
        (jsonDecode(metadata.body) as Map<String, dynamic>)['issuer'],
        'https://bsky.social',
      );
    });
  });
}

// ---- Fixtures ---------------------------------------------------------------

/// Records and answers JSON routes on a plain-HTTP origin.
class _JsonFixture {
  _JsonFixture._(this._server);
  final HttpServer _server;
  final Map<String, void Function(HttpRequest)> _routes = {};

  String get origin => 'http://127.0.0.1:${_server.port}';

  static Future<_JsonFixture> start(
      Map<String, void Function(HttpRequest)> routes) async {
    final fixture = _JsonFixture._(await HttpServer.bind('127.0.0.1', 0));
    fixture._routes.addAll(routes);
    fixture._server.listen((request) {
      final handler = fixture._routes[request.uri.path];
      if (handler == null) {
        _respond(request, 404, {'error': 'NotFound'});
      } else {
        handler(request);
      }
    });
    return fixture;
  }

  Future<void> stop() => _server.close(force: true);
}

void _respond(HttpRequest request, int status, Object body,
    {bool raw = false, Map<String, String> extraHeaders = const {}}) {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  extraHeaders.forEach(request.response.headers.set);
  request.response.write(raw ? body : jsonEncode(body));
  request.response.close();
}

/// A sharded Bluesky PDS stand-in over plain HTTP: entryway XRPC + DID
/// documents (serviceEndpoint = itself) + the protected-resource
/// document pointing at the AS host — and a 404 on the
/// oauth-authorization-server path, exactly the live topology that
/// broke sign-in before the hop existed.
class _ShardedPds {
  _ShardedPds._(this._server, this._identities, this._authorizationServers);
  final HttpServer _server;
  final Map<String, String> _identities; // handle -> did
  final List<String> _authorizationServers;
  final requestedPaths = <String>[];

  String get origin => 'http://127.0.0.1:${_server.port}';

  static Future<_ShardedPds> start({
    required Map<String, String> identities,
    required List<String> authorizationServers,
  }) async {
    final pds = _ShardedPds._(
        await HttpServer.bind('127.0.0.1', 0), identities, authorizationServers);
    pds._server.listen((request) => unawaited(pds._handle(request)));
    return pds;
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requestedPaths.add('${request.method} $path');
    if (path == '/xrpc/com.atproto.identity.resolveHandle' &&
        request.method == 'GET') {
      final did = _identities[request.uri.queryParameters['handle']];
      if (did == null) {
        _respond(request, 400, {'error': 'invalid_request'});
      } else {
        _respond(request, 200, {'did': did});
      }
      return;
    }
    if (path.startsWith('/did:') && request.method == 'GET') {
      _respond(request, 200, {
        '@context': ['https://www.w3.org/ns/did/v1'],
        'id': path.substring('/did:'.length),
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
    if (path == '/.well-known/oauth-protected-resource' &&
        request.method == 'GET') {
      _respond(request, 200, {
        'resource': origin,
        'authorization_servers': _authorizationServers,
        'scopes_supported': const [],
        'bearer_methods_supported': const ['header'],
        'resource_documentation': 'https://atproto.com',
      });
      return;
    }
    if (path == '/.well-known/oauth-authorization-server') {
      // The live bug: sharded PDS hosts have no AS metadata.
      _respond(request, 404, {'error': 'NotFound'});
      return;
    }
    _respond(request, 404, {'error': 'NotFound'});
  }

  Future<void> stop() => _server.close(force: true);
}

/// A minimal node with the atproto provider wired, identity pointed at
/// [identityBase] (entryway + PLC directory roles).
class _DiscoveryNode {
  _DiscoveryNode._(this.listener, this.supervisor, this.store);
  final RoomsListener listener;
  final RoomSupervisor supervisor;
  final NodeStore store;

  late final Uri base = Uri.parse('http://127.0.0.1:${listener.port}');

  static const apiKey = 'sk_discovery_test';

  static Future<_DiscoveryNode> start({
    required String identityBase,
    required http.Client Function() httpClientFactory,
  }) async {
    final store = NodeStore.open(':memory:')
      ..seedApiKeys({'default': apiKey});
    final tokens = JoinTokens('node-secret'.codeUnits);
    final supervisor = RoomSupervisor(
      factories: [
        RelayAuthorityFactory(
          creatorVerify: (roomKey, token) => tokens.verify(
            token,
            roomKey: roomKey,
            now: DateTime.now().toUtc(),
          ),
        ),
      ],
      maxRooms: 64,
    )..startTicker(hz: 60);
    final provider = AtprotoAuthProvider(
      publicBaseUrl: 'http://127.0.0.1:0', // corrected once bound, below
      keys: await NodeClientKeys.generate(),
      tokens: tokens,
      identityResolver: NodeAtprotoResolver(
        entrywayUrl: identityBase,
        plcDirectoryUrl: identityBase,
        httpClient: httpClientFactory(),
        allowPrivateNetwork: true,
      ),
      httpClientFactory: httpClientFactory,
      allowPrivateNetwork: true,
    );
    final listener = RoomsListener(
      supervisor: supervisor,
      api: ControlPlaneApi(
        supervisor: supervisor,
        store: store,
        platform: SqlitePlatformStore(store, adminDids: const []),
        tokens: tokens,
        publicBaseUrl: 'http://127.0.0.1:0',
      ),
      store: store,
      tokens: tokens,
      tokenLedger: store,
      originGate: OriginGate(const []),
      throttle: IpThrottle(maxPerWindow: 1000),
      atproto: provider,
    );
    await listener.start(port: 0, address: '127.0.0.1');
    provider.publicBaseUrl = 'http://127.0.0.1:${listener.port}';
    return _DiscoveryNode._(listener, supervisor, store);
  }

  Future<void> stop() async {
    await listener.close();
    await supervisor.close();
    store.close();
  }

  /// Creates a live relay room (sign-in binds to a real room) and
  /// returns its room key.
  Future<String> createRoom(http.Client client) async {
    final response = await client.post(base.replace(path: '/v1/rooms'),
        headers: {'Authorization': 'Bearer $apiKey'},
        body: jsonEncode({
          'template': 'relay',
          'config': {
            'version': 1,
            'template': 'relay',
            'capacity': 8,
            'maxRows': 64,
            'totalBytes': 32768,
            'playerKeys': {
              'pose': {'maxBytes': 256, 'publishesPerSecond': 10},
            },
            'roomKeys': {
              'phase': {'maxBytes': 64, 'publishesPerSecond': 1},
            },
          },
        }));
    expect(response.statusCode, 201, reason: response.body);
    return (jsonDecode(response.body) as Map<String, dynamic>)['roomKey']
        as String;
  }
}

/// Drives `/auth/start` → browser → `/auth/result`; returns the
/// completed flow's result map.
Future<Map<String, dynamic>> _signIn(
  _DiscoveryNode node,
  String handle, {
  required http.Client client,
}) async {
  final start = await client.get(node.base.replace(
    path: '/auth/start',
    queryParameters: {
      'handle': handle,
      'room': await node.createRoom(client),
      'format': 'json',
    },
  ));
  expect(start.statusCode, 200, reason: start.body);
  final startBody = jsonDecode(start.body) as Map<String, dynamic>;
  expect(startBody['authorizationUrl'], isA<String>());

  // The "browser": follow the authorization URL (the fake AS approves).
  final browser =
      await client.get(Uri.parse(startBody['authorizationUrl'] as String));
  expect(browser.statusCode, anyOf(200, 302), reason: browser.body);

  for (var i = 0; i < 100; i++) {
    final response = await client.get(node.base.replace(
      path: '/auth/result',
      queryParameters: {'flow': startBody['flow'] as String},
    ));
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['status'] == 'pending') {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      continue;
    }
    expect(body['status'], 'ok', reason: response.body);
    return {...body, 'authorizationUrl': startBody['authorizationUrl']};
  }
  fail('sign-in never completed');
}

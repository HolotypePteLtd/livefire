import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

import 'atproto_world.dart';

/// `private_key_jwt` client authentication (RFC 7523) on BOTH the
/// pushed authorization request and the token endpoint — the
/// live-confirmed gap (bsky.social rejects PAR with `client
/// authentication method "private_key_jwt" required a
/// "client_assertion"`).
///
/// The fixture AS (`FakeAtprotoWorld`) enforces — and verifies — the
/// assertion at PAR and at the token endpoint: JWS shape, ES256
/// header, `kid` from the served JWKS, iss/sub = client_id,
/// aud = the AS issuer origin, sane iat/exp window, ECDSA signature
/// over the signing input. These tests drive the whole sign-in through
/// that enforcing AS and additionally exercise the verifier's
/// rejection paths with hand-built assertions.
void main() {
  final world = FakeAtprotoWorld();
  setUpAll(() async {
    await world.start();
    world.addIdentity('player.bsky.social', 'did:plc:player');
  });
  tearDownAll(() => world.stop());
  setUp(() {
    world.clientMetadata = null;
    world.clientJwks = null;
    world.problems.clear();
  });

  /// Decodes an assertion's header + claims for structural assertions.
  (Map<String, dynamic>, Map<String, dynamic>) decode(String jwt) {
    final parts = jwt.split('.');
    Map<String, dynamic> part(int i) =>
        jsonDecode(utf8.decode(base64Url.decode(parts[i].padRight(
            (parts[i].length + 3) & ~3, '=')))) as Map<String, dynamic>;
    return (part(0), part(1));
  }

  test('sign-in completes against an AS that demands the assertion at PAR',
      () async {
    final node = await _AssertionNode.start(world);
    addTearDown(node.stop);

    final result = await _signIn(node, world);
    expect(result['did'], 'did:plc:player');
    expect(result['joinToken'] as String, startsWith('jt_'));

    // The enforcing AS saw no protocol problems along the way.
    expect(world.problems, isEmpty,
        reason: 'fixture AS recorded: ${world.problems}');
  });

  test('both PAR and the token call carry a valid client_assertion', () async {
    final node = await _AssertionNode.start(world);
    addTearDown(node.stop);
    await _signIn(node, world);

    // PAR: the form the AS stored carries the assertion pair.
    expect(world.parForms, isNotEmpty);
    final par = world.parForms.values.last;
    expect(par['client_assertion_type'], FakeAtprotoWorld.assertionType);
    final parAssertion = par['client_assertion']!;
    expect(parAssertion.split('.').length, 3);

    // Token: same, on the authorization_code grant.
    expect(world.tokenCalls, isNotEmpty);
    final token = world.tokenCalls.last;
    expect(token['grant_type'], 'authorization_code');
    expect(token['client_assertion_type'], FakeAtprotoWorld.assertionType);
    final tokenAssertion = token['client_assertion']!;
    expect(tokenAssertion.split('.').length, 3);

    // The claims template, checked on both assertions.
    for (final assertion in [parAssertion, tokenAssertion]) {
      final (header, claims) = decode(assertion);
      expect(header['alg'], 'ES256');
      expect(header['typ'], 'JWT');
      // kid must select the key the node serves at /oauth/jwks.json.
      final servedKid =
          (node.keys.publicJwks()['keys'] as List).first['kid'];
      expect(header['kid'], servedKid);

      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      expect(claims['iss'], node.clientId);
      expect(claims['sub'], node.clientId);
      expect(claims['aud'], world.origin); // the AS issuer, not the endpoint
      expect(claims['iat'] as int, lessThanOrEqualTo(now + 60));
      expect(claims['exp'] as int, greaterThan(now));
      expect((claims['exp'] as int) - (claims['iat'] as int), inInclusiveRange(60, 300));
      expect(claims['jti'] as String, isNotEmpty);
    }
  });

  test('an unauthenticated PAR is rejected like the real AS rejects it',
      () async {
    final node = await _AssertionNode.start(world);
    addTearDown(node.stop);
    await _signIn(node, world); // loads the AS's client metadata record

    final client = world.newClient();
    final response = await client.post(
      Uri.parse('${world.origin}/oauth/par'),
      body: {
        'client_id': node.clientId,
        'redirect_uri': '${node.base}/auth/callback',
        'state': 's',
        'code_challenge': 'c',
        'code_challenge_method': 'S256',
        'response_type': 'code',
      },
    );
    expect(response.statusCode, 401);
    expect(jsonDecode(response.body)['error'], 'invalid_client');
  });

  test('the wrapper is transparent: DPoP header, form fields and URL all '
      'survive the assertion attach', () async {
    // Audit regression (atproto_oauth 0.8.3 token path vs the
    // ConfidentialClient wrapper): the library posts the token request
    // with a DPoP proof header and caches nonces per endpoint ORIGIN.
    // The wrapper must append the assertion pair without touching the
    // header, the existing fields, or the URL — a re-encoded body or
    // rewritten host would invalidate the proof / the nonce cache.
    final received = <({String method, Uri url, String? dpop, Map<String, String> form})>[];
    final recorder = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => recorder.close(force: true));
    recorder.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      received.add((
        method: request.method,
        url: request.uri,
        dpop: request.headers.value('DPoP'),
        form: Uri.splitQueryString(body),
      ));
      request.response.statusCode = 200;
      request.response.write('{}');
      await request.response.close();
    });

    final keys = await NodeClientKeys.generate();
    const clientId = 'https://rooms.example.com/oauth/client.json';
    final wrapper = ConfidentialClient(
        keys: keys, clientId: clientId, inner: http.Client());
    addTearDown(wrapper.close);

    final endpoint = Uri.parse('http://127.0.0.1:${recorder.port}/oauth/token');
    const dpopProof = 'eyJhbGciOiJFUzI1NiIsImtpZCI6ImEtYi1jIn0.proof.sig';
    final request = http.Request('POST', endpoint)
      ..headers['DPoP'] = dpopProof
      ..bodyFields = {
        'client_id': clientId,
        'grant_type': 'authorization_code',
        'code': 'code_7',
        'redirect_uri': 'https://rooms.example.com/auth/callback',
        'code_verifier': 's3cr3t-verifier',
      };
    final response = await http.Response.fromStream(await wrapper.send(request));
    expect(response.statusCode, 200);

    expect(received.single.method, 'POST');
    // The request arrived at the intended server with the intended
    // path — the wrapper never rewrites hosts, so the library's
    // per-origin DPoP nonce cache stays coherent.
    expect(received.single.url.path, endpoint.path);
    expect(received.single.dpop, dpopProof); // proof untouched (covers
    // htm/htu only — RFC 9449 — so appending form fields cannot break it)
    expect(received.single.form, containsPair('grant_type', 'authorization_code'));
    expect(received.single.form, containsPair('code', 'code_7'));
    expect(received.single.form, containsPair('code_verifier', 's3cr3t-verifier'));
    expect(received.single.form['client_assertion_type'], FakeAtprotoWorld.assertionType);
    final assertion = received.single.form['client_assertion']!;
    expect(assertion.split('.').length, 3);
    // The appended assertion is well-formed for THIS audience.
    final (_, claims) = decode(assertion);
    expect(claims['iss'], clientId);
    expect(claims['aud'], endpoint.origin);
  });

  test('the verifier rejects wrong aud / iss / sub / kid / time / shape',
      () async {
    final node = await _AssertionNode.start(world);
    addTearDown(node.stop);
    await _signIn(node, world); // clientMetadata + clientJwks on record

    String assertion({
      String? aud,
      String? iss,
      String? sub,
      String? kid,
      Duration expIn = const Duration(minutes: 2),
      Duration iatAgo = Duration.zero,
    }) =>
        node.keys.signJwt(
          {
            'alg': 'ES256',
            'typ': 'JWT',
            'kid': kid ?? node.keys.kid,
          },
          {
            'iss': iss ?? node.clientId,
            'sub': sub ?? node.clientId,
            'aud': aud ?? world.origin,
            'iat': DateTime.now()
                    .toUtc()
                    .subtract(iatAgo)
                    .millisecondsSinceEpoch ~/
                1000,
            'exp': DateTime.now()
                    .toUtc()
                    .add(expIn)
                    .millisecondsSinceEpoch ~/
                1000,
            'jti': 'test',
          },
        );

    // The well-formed one verifies…
    expect(world.verifyClientAssertion(assertion(), where: 'test'), isTrue,
        reason: 'sanity: ${world.problems}');
    final before = world.problems.length;
    // …and every deviation is rejected, each with a recorded reason.
    expect(world.verifyClientAssertion(assertion(aud: 'https://evil.example'),
        where: 'test'),
        isFalse);
    expect(world.verifyClientAssertion(assertion(iss: 'https://evil.example'),
        where: 'test'),
        isFalse);
    expect(world.verifyClientAssertion(assertion(sub: 'https://evil.example'),
        where: 'test'),
        isFalse);
    expect(
        world.verifyClientAssertion(assertion(kid: 'unknown-kid'),
            where: 'test'),
        isFalse);
    expect(
        world.verifyClientAssertion(
            assertion(expIn: const Duration(minutes: -1)), where: 'test'),
        isFalse);
    expect(
        world.verifyClientAssertion(
            assertion(iatAgo: const Duration(minutes: -5)), where: 'test'),
        isFalse);
    expect(world.verifyClientAssertion('not.a.jwt', where: 'test'), isFalse);
    expect(world.verifyClientAssertion('', where: 'test'), isFalse);
    // Every rejection produced exactly one problem line.
    expect(world.problems.length, before + 8);
  });
}

/// A minimal node whose provider signs with a known key pair (exposed
/// for claim/kid assertions and hand-built test assertions).
class _AssertionNode {
  _AssertionNode._(this.listener, this.supervisor, this.store, this.keys,
      this.provider);

  final RoomsListener listener;
  final RoomSupervisor supervisor;
  final NodeStore store;
  final NodeClientKeys keys;
  final AtprotoAuthProvider provider;

  late final Uri base = Uri.parse('http://127.0.0.1:${listener.port}');
  String get clientId => provider.clientId;

  static const apiKey = 'sk_assertion_test';

  static Future<_AssertionNode> start(FakeAtprotoWorld world) async {
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
    final keys = await NodeClientKeys.generate();
    final provider = AtprotoAuthProvider(
      publicBaseUrl: 'http://127.0.0.1:0', // corrected once bound, below
      keys: keys,
      tokens: tokens,
      identityResolver: NodeAtprotoResolver(
        entrywayUrl: world.origin,
        plcDirectoryUrl: world.origin,
        httpClient: world.newClient(),
        allowPrivateNetwork: true,
      ),
      httpClientFactory: world.newClient,
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
    return _AssertionNode._(
        listener, supervisor, store, keys, provider);
  }

  Future<void> stop() async {
    await listener.close();
    await supervisor.close();
    store.close();
  }

  Future<String> createRoom() async {
    final response = await http.post(base.replace(path: '/v1/rooms'),
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

Future<Map<String, dynamic>> _signIn(
    _AssertionNode node, FakeAtprotoWorld world) async {
  final start = await http.get(node.base.replace(
    path: '/auth/start',
    queryParameters: {
      'handle': 'player.bsky.social',
      'room': await node.createRoom(),
      'format': 'json',
    },
  ));
  expect(start.statusCode, 200, reason: start.body);
  final startBody = jsonDecode(start.body) as Map<String, dynamic>;
  // The "browser": follow the authorization URL (the fake AS approves).
  await world.client
      .get(Uri.parse(startBody['authorizationUrl'] as String));
  for (var i = 0; i < 100; i++) {
    final result = await http.get(node.base.replace(
      path: '/auth/result',
      queryParameters: {'flow': startBody['flow'] as String},
    ));
    final body = jsonDecode(result.body) as Map<String, dynamic>;
    if (body['status'] == 'pending') {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      continue;
    }
    expect(body['status'], 'ok', reason: result.body);
    return body;
  }
  fail('sign-in never completed');
}

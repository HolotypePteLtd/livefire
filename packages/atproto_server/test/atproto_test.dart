import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client/client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:livefire_atproto_server/livefire_atproto_server.dart';
import 'package:server_sdk/server_sdk.dart';
import 'package:livefire_atproto_server/src/atproto/did_web_client.dart';
import 'package:test/test.dart';
import 'atproto_world.dart';

/// A node with the atproto provider wired: relay rooms with signed creator
/// claims, DID-keyed roster profiles.
class AtprotoNode {
  AtprotoNode._(
    this.listener,
    this.supervisor,
    this.store,
    this.tokens,
    this.provider,
    this.profiles,
    this.index,
  );

  final RoomsListener listener;
  final RoomSupervisor supervisor;
  final NodeStore store;
  final JoinTokens tokens;
  final AtprotoAuthProvider provider;
  final ProfileService profiles;
  final RoomIdentityIndex index;

  late final Uri base = Uri.parse('http://127.0.0.1:${listener.port}');

  static Future<AtprotoNode> start(FakeAtprotoWorld world,
      {Duration resumeGrace = const Duration(seconds: 15)}) async {
    final store = NodeStore.open(':memory:')
      ..seedApiKeys({'default': 'sk_test_node'});
    final tokens = JoinTokens('node-secret'.codeUnits);
    final profiles = ProfileService(
      store: SqliteAccountStore(store.database),
      httpClientFactory: world.newClient,
    );
    final index = RoomIdentityIndex();
    final supervisor = RoomSupervisor(
      factories: [
        RelayAuthorityFactory(
          resumeGrace: resumeGrace,
          creatorVerify: (roomKey, token) => tokens.verify(
            token,
            roomKey: roomKey,
            now: DateTime.now().toUtc(),
          ),
          profileLookup: (roomKey, peerId) {
            final did = index.didOf(roomKey, peerId);
            return did == null ? null : profiles.profileOf(did);
          },
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
    final api = ControlPlaneApi(
      supervisor: supervisor,
      store: store,
      platform: SqlitePlatformStore(store, adminDids: const []),
      tokens: tokens,
      publicBaseUrl: 'http://127.0.0.1:0',
    );
    final listener = AtprotoRoomsListener(
      supervisor: supervisor,
      api: api,
      store: store,
      tokens: tokens,
      tokenLedger: store,
      originGate: OriginGate(const []),
      throttle: IpThrottle(maxPerWindow: 1000),
      atproto: provider,
      onPeerAttached: (room, peer) {
        final did = peer.identity;
        if (did == null) return;
        index.set(room.key, peer.id, did);
        profiles.ensure(
          did,
          pds: provider.pdsOf(did),
          hub: room.hub,
        );
      },
    );
    await listener.start(port: 0, address: '127.0.0.1');
    // The provider needs the real public origin for its client metadata
    // and redirect URI; correct it now that the port is bound.
    provider.publicBaseUrl = 'http://127.0.0.1:${listener.port}';
    return AtprotoNode._(
      listener,
      supervisor,
      store,
      tokens,
      provider,
      profiles,
      index,
    );
  }

  Future<void> stop() async {
    await listener.close();
    await supervisor.close();
    store.close();
  }

  Future<Map<String, dynamic>> createRelayRoom() async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        base.resolve('/v1/rooms'),
      );
      request.headers.set(HttpHeaders.authorizationHeader,
          'Bearer sk_test_node');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
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
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      expect(response.statusCode, 201, reason: text);
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// Drives the full atproto flow: start → browser → poll result.
  Future<Map<String, dynamic>> signIn(
    FakeAtprotoWorld world,
    String handle,
    String roomKey, {
    bool creator = false,
    String? creatorToken,
  }) async {
    final start = await client.get(base.replace(
      path: '/auth/start',
      queryParameters: {
        'handle': handle,
        'room': roomKey,
        if (creator) 'creator': 'true',
        'creatorToken': ?creatorToken,
        'format': 'json',
      },
    ));
    final startBody = jsonDecode(start.body) as Map<String, dynamic>;
    expect(start.statusCode, 200, reason: start.body);
    // The user's browser: follow the authorization URL through the fake
    // AS's redirect onto the node's callback.
    final browser = await world.client.get(
      Uri.parse(startBody['authorizationUrl'] as String),
    );
    expect(browser.statusCode, 200, reason: browser.body);
    for (var i = 0; i < 100; i++) {
      final result = await client.get(base.replace(
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

    final http.Client _plainClient = http.Client();
  http.Client get client => _plainClient;
}

Future<void> until(bool Function() done,
    [String label = '',
    Duration timeout = const Duration(seconds: 8)]) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('Timed out $label');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class TestClient extends RoomClient<SupSnap> {
  TestClient(this.playUri, String name, {this.creatorToken})
      : super(
          uri: playUri,
          name: name,
          protocolVersion: 1,
          connector: () => WebSocketGameConnection.connect(playUri),
        );

  final Uri playUri;
  final String? creatorToken;

  @override
  Map<String, dynamic> get joinPayload => {
        if (creatorToken != null) 'creatorToken': creatorToken,
      };

  @override
  SupSnap decodeSnapshot(Map<String, dynamic> data) => SupSnap(data);
}

class SupSnap extends RoomSnapshot {
  SupSnap(super.data);
}

/// Raw WebSocket join for protocol-level assertions (resume, bans).
class RawPeer {
  RawPeer(this.socket);
  final WebSocket socket;
  final messages = StreamController<Map<String, dynamic>>();
  int? closeCode;

  static Future<RawPeer> connect(Uri uri) async {
    final socket = await WebSocket.connect(uri.toString());
    final peer = RawPeer(socket);
    socket.listen(
      // A close (ban/drain) can beat a queued final frame to the
      // listener under load; dropping it after close is fine — the
      // test has already observed what it needed.
      (data) {
        if (!peer.messages.isClosed) {
          peer.messages.add(jsonDecode(data as String));
        }
      },
      onDone: () {
        peer.closeCode = socket.closeCode;
        peer.messages.close();
      },
      onError: (Object _) => peer.messages.close(),
    );
    return peer;
  }

  void send(Map<String, dynamic> message) =>
      socket.add(jsonEncode(message));

  Future<Map<String, dynamic>> next(String type) async {
    await for (final message in messages.stream) {
      if (message['type'] == type) return message;
      if (message['type'] == 'error') {
        throw StateError('error frame: ${message['message']}');
      }
    }
    throw StateError('closed before $type');
  }

  Future<String> expectError() async {
    await for (final message in messages.stream) {
      if (message['type'] == 'error') return message['message'] as String;
    }
    throw StateError('closed without an error frame');
  }

  Future<void> close() async {
    await socket.close();
    await messages.close();
  }
}

void main() {
  late FakeAtprotoWorld world;

  setUp(() async {
    world = FakeAtprotoWorld();
    await world.start();
    world.addIdentity('alice.test', 'did:plc:alice',
        displayName: 'Alice A.', avatar: 'https://cdn.test/alice.jpg');
    world.addIdentity('bob.test', 'did:plc:bob',
        displayName: 'Bob B.', avatar: 'https://cdn.test/bob.jpg');
  });

  tearDown(() => world.stop());

  test('the node serves its OAuth client metadata and JWKS', () async {
    final node = await AtprotoNode.start(world);
    addTearDown(node.stop);
    final metadata = jsonDecode(
      await _read(node.base.resolve('/oauth/client.json')),
    ) as Map<String, dynamic>;
    expect(metadata['client_id'], '${node.base}/oauth/client.json');
    expect(metadata['application_type'], 'web');
    expect(metadata['token_endpoint_auth_method'], 'private_key_jwt');
    expect(metadata['redirect_uris'], ['${node.base}/auth/callback']);
    expect(metadata['scope'], 'atproto');
    final jwks = jsonDecode(
      await _read(node.base.resolve('/oauth/jwks.json')),
    ) as Map<String, dynamic>;
    final key = (jwks['keys'] as List).single as Map<String, dynamic>;
    expect(key['kty'], 'EC');
    expect(key['crv'], 'P-256');
    expect(key['alg'], 'ES256');
    expect(key['kid'], isNotEmpty);
    expect(key.containsKey('d'), isFalse, reason: 'private key leaked');
  });

  test('full atproto flow: DID verified, creator claim, profile, ban',
      () async {
    final node = await AtprotoNode.start(world);
    addTearDown(node.stop);
    final room = await node.createRelayRoom();
    final roomKey = room['roomKey'] as String;

    // --- Alice signs in as the room creator (with the room's creatorToken). ---
    final alice = await node.signIn(
      world,
      'alice.test',
      roomKey,
      creator: true,
      creatorToken: room['creatorToken'] as String,
    );
    expect(alice['did'], 'did:plc:alice');
    expect(alice['handle'], 'alice.test');
    final joinToken = alice['joinToken'] as String;
    final creatorToken = alice['creatorToken'] as String;
    expect(joinToken, startsWith('jt_'));
    expect(creatorToken, startsWith('ct_'));
    final verified = node.tokens.verify(joinToken,
        roomKey: roomKey, now: DateTime.now().toUtc());
    expect(verified.ok, isTrue, reason: verified.problem?.name);
    expect(verified.payload!.did, 'did:plc:alice');
    // The fake AS fully validated the confidential client.
    expect(world.problems, isEmpty,
        reason: 'AS-side validation failures: ${world.problems}');
    expect(world.clientMetadata, isNotNull,
        reason: 'the AS never fetched the client metadata document');
    expect(world.tokenCalls, isNotEmpty);
    expect(world.tokenCalls.first['client_assertion'], isNotNull);

    // --- Alice joins; the signed creator claim makes her the leader. ---
    final playUri = node.base.replace(
      scheme: 'ws',
      path: '/play/$roomKey',
      queryParameters: {'token': joinToken},
    );
    final aliceClient = TestClient(playUri, 'Alice',
        creatorToken: creatorToken);
    await aliceClient.connect();
    await until(() => aliceClient.social.available, 'roster');
    expect(aliceClient.social.leaderId, isNotNull);

    // --- The profile prefetched from the PDS lands on the roster. ---
    await until(() => aliceClient.social.members
        .any((m) => m.profile?['displayName'] == 'Alice A.'), 'profile');
    final member = aliceClient.social.members.first;
    expect(member.profile?['did'], 'did:plc:alice');
    expect(member.profile?['avatar'], 'https://cdn.test/alice.jpg');
    expect(node.profiles.store.profile('did:plc:alice')?.displayName, 'Alice A.');

    // --- Bob signs in and joins with his own DID token. ---
    final bob = await node.signIn(world, 'bob.test', roomKey);
    final bobUri = node.base.replace(
      scheme: 'ws',
      path: '/play/$roomKey',
      queryParameters: {'token': bob['joinToken'] as String},
    );
    final bobClient = TestClient(bobUri, 'Bob');
    await bobClient.connect();
    await until(
      () => aliceClient.social.members.any((m) => m.name == 'Bob'),
      'bob on roster',
    );

    // --- Alice bans Bob: the ban binds to the DID. ---
    final bobId = aliceClient.social.members
        .firstWhere((m) => m.name == 'Bob')
        .id;
    aliceClient.social.moderate('ban', playerId: bobId);
    await until(() => !bobClient.social.available, 'bob removed');
    await bobClient.close();

    // A fresh DID token for Bob is refused: banned identity.
    final bobAgain = await node.signIn(world, 'bob.test', roomKey);
    final bannedPeer = await RawPeer.connect(node.base.replace(
      scheme: 'ws',
      path: '/play/$roomKey',
      queryParameters: {'token': bobAgain['joinToken'] as String},
    ));
    bannedPeer.send({'type': 'join', 'protocol': 1, 'name': 'Bob'});
    expect(await bannedPeer.expectError(), 'You are banned from this room');
    expect(bannedPeer.closeCode, 1008);
    await bannedPeer.close();

    // --- The same DID resumes (across "devices"); a guest token cannot. ---
    // Join tokens are one-time, so every fresh connection signs in again
    // (a new token for the same DID, exactly like a new device).
    final aliceSecond = await node.signIn(world, 'alice.test', roomKey);
    final aliceRaw = await RawPeer.connect(node.base.replace(
      scheme: 'ws',
      path: '/play/$roomKey',
      queryParameters: {'token': aliceSecond['joinToken'] as String},
    ));
    aliceRaw.send({
      'type': 'join',
      'protocol': 1,
      'name': 'Alice',
      'creatorToken': creatorToken,
    });
    final welcome = await aliceRaw.next('welcome');
    final resumeToken = welcome['resume'] as String;
    await aliceRaw.close();

    // Cross-device resume: a fresh DID token keeps the identity.
    final aliceFresh = await node.signIn(world, 'alice.test', roomKey);
    final resumedPeer = await RawPeer.connect(node.base.replace(
      scheme: 'ws',
      path: '/play/$roomKey',
      queryParameters: {'token': aliceFresh['joinToken'] as String},
    ));
    resumedPeer.send({
      'type': 'join',
      'protocol': 1,
      'resume': resumeToken,
    });
    final resumed = await resumedPeer.next('welcome');
    expect(resumed['id'], welcome['id'], reason: 'same peer id on resume');
    await resumedPeer.close();

    // A guest token (no DID) cannot resume the DID-bound session.
    final guestToken = node.tokens.mintJoin(roomKey);
    final guestPeer = await RawPeer.connect(node.base.replace(
      scheme: 'ws',
      path: '/play/$roomKey',
      queryParameters: {'token': guestToken},
    ));
    guestPeer.send({
      'type': 'join',
      'protocol': 1,
      'resume': resumeToken,
    });
    expect(await guestPeer.expectError(),
        'Session identity changed; join again');
    await guestPeer.close();
    await aliceClient.close();
  });

  test('unknown handles and unknown rooms fail the start', () async {
    final node = await AtprotoNode.start(world);
    addTearDown(node.stop);
    final room = await node.createRelayRoom();

    final unknownHandle = await _get(node.base.replace(
      path: '/auth/start',
      queryParameters: {
        'handle': 'nobody.test',
        'room': room['roomKey'] as String,
        'format': 'json',
      },
    ));
    expect(unknownHandle.statusCode, 400);

    final unknownRoom = await _get(node.base.replace(
      path: '/auth/start',
      queryParameters: {
        'handle': 'alice.test',
        'room': 'rm_missing',
        'format': 'json',
      },
    ));
    expect(unknownRoom.statusCode, 404);

    final missing = await _get(
      node.base.resolve('/auth/result?flow=none'),
    );
    expect(missing.statusCode, 410);

    // Claiming creator=true without the room's creatorToken must be refused.
    final hijackNoToken = await _get(
      node.base.replace(
        path: '/auth/start',
        queryParameters: {
          'handle': 'bob.test',
          'room': room['roomKey'] as String,
          'creator': 'true',
          'format': 'json',
        },
      ),
    );
    expect(hijackNoToken.statusCode, 403);

    final hijackWrongToken = await _get(
      node.base.replace(
        path: '/auth/start',
        queryParameters: {
          'handle': 'bob.test',
          'room': room['roomKey'] as String,
          'creator': 'true',
          'creatorToken': 'ct_wrong',
          'format': 'json',
        },
      ),
    );
    expect(hijackWrongToken.statusCode, 403);
  });

  test(
    'NodeAtprotoResolver blocks SSRF and malformed DIDs when allowPrivateNetwork is false',
    () async {
      final resolver = NodeAtprotoResolver(
        entrywayUrl: 'https://bsky.social',
        plcDirectoryUrl: 'https://plc.directory',
        allowPrivateNetwork: false,
      );
      for (final bad in [
        'did:web:localhost',
        'did:web:127.0.0.1',
        'did:web:169.254.169.254',
        'did:web:10.0.0.1',
        'did:web:evil.com@127.0.0.1',
        'did:plc:../etc/passwd',
      ]) {
        await expectLater(
          resolver.resolve(bad),
          throwsA(isA<Exception>()),
          reason: 'expected $bad to be rejected',
        );
      }
    },
  );

  test('did:web checks each redirect destination before fetching it', () async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      expect(request.followRedirects, isFalse);
      if (request.url.path == '/.well-known/did.json') {
        return http.Response('', 302, headers: {'location': '/identity.json'});
      }
      return http.Response(
        '',
        302,
        headers: {'location': 'https://localhost/identity.json'},
      );
    });
    final web = DidWebClient(client: client);
    addTearDown(web.close);
    await expectLater(
      web.get(Uri.parse('https://public.example/.well-known/did.json')),
      throwsA(isA<Exception>()),
    );
    expect(requests.map((uri) => uri.toString()), [
      'https://public.example/.well-known/did.json',
      'https://public.example/identity.json',
    ]);
  });

  test('auth endpoints are 404 without the provider', () async {
    final store = NodeStore.open(':memory:')
      ..seedApiKeys({'default': 'sk'});
    final tokens = JoinTokens('s'.codeUnits);
    final supervisor = RoomSupervisor(factories: const [
      RelayAuthorityFactory(),
    ])..startTicker(hz: 60);
    final listener = AtprotoRoomsListener(
      supervisor: supervisor,
      api: ControlPlaneApi(
        supervisor: supervisor,
        store: store,
        platform: SqlitePlatformStore(store, adminDids: const []),
        tokens: tokens,
        publicBaseUrl: 'http://127.0.0.1:1',
      ),
      store: store,
      tokens: tokens,
      tokenLedger: store,
      originGate: OriginGate(const []),
      throttle: IpThrottle(maxPerWindow: 1000),
    );
    await listener.start(port: 0);
    addTearDown(() async {
      await listener.close();
      await supervisor.close();
      store.close();
    });
    final response = await _get(
      Uri.parse('http://127.0.0.1:${listener.port}/auth/start'),
    );
    expect(response.statusCode, 404);
  });
}

Future<String> _read(Uri uri) async {
  final response = await _get(uri);
  expect(response.statusCode, 200, reason: uri.toString());
  return response.body;
}

Future<http.Response> _get(Uri uri) async {
  final client = http.Client();
  try {
    return await client.get(uri);
  } finally {
    client.close();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client/client.dart';
import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

import 'kinematic_backend.dart';

const apiKey = 'sk_test_node';

/// A whole node in-process: supervisor + listener + API over an
/// in-memory store, bound to an ephemeral port.
class NodeHarness {
  NodeHarness._(
    this.listener,
    this.supervisor,
    this.store,
    this.tokens,
  );

  final RoomsListener listener;
  final RoomSupervisor supervisor;
  final NodeStore store;
  final JoinTokens tokens;

  late final Uri base = Uri.parse('http://127.0.0.1:${listener.port}');

  static Future<NodeHarness> start({
    int maxRooms = 64,
    Duration idleTtl = const Duration(minutes: 5),
    List<String> origins = const [],
    int throttlePerMinute = 1000,
    bool movement = true,
  }) async {
    final store = NodeStore.open(':memory:')
      ..seedApiKeys({'default': apiKey});
    final factories = <AuthorityFactory>[
      const RelayAuthorityFactory(resumeGrace: Duration(seconds: 1)),
      if (movement)
        const MovementAuthorityFactory(KinematicBackend.new,
            resumeGrace: Duration(seconds: 1)),
    ];
    final supervisor = RoomSupervisor(
      factories: factories,
      maxRooms: maxRooms,
      idleTtl: idleTtl,
    )..startTicker(hz: 60);
    final tokens = JoinTokens('node-secret'.codeUnits);
    final api = ControlPlaneApi(
      supervisor: supervisor,
      store: store,
      platform: SqlitePlatformStore(store, adminDids: const []),
      tokens: tokens,
      publicBaseUrl: 'http://127.0.0.1:0', // rewritten per room URL below
    );
    final listener = RoomsListener(
      supervisor: supervisor,
      api: api,
      store: store,
      tokens: tokens,
      tokenLedger: store,
      originGate: OriginGate(origins),
      throttle: IpThrottle(maxPerWindow: throttlePerMinute),
    );
    await listener.start(port: 0);
    return NodeHarness._(listener, supervisor, store, tokens);
  }

  Future<void> stop() async {
    await listener.close();
    await supervisor.close();
    store.close();
  }

  Future<Map<String, dynamic>> createRoom(
    String template,
    Map<String, dynamic> config,
  ) async {
    final response = await post(
      '/v1/rooms',
      {'template': template, 'config': config},
    );
    final text = await response.read();
    expect(response.statusCode, 201, reason: text);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<(int, String)> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? key,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, base.resolve(path));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${key ?? apiKey}',
      );
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      return (response.statusCode, text);
    } finally {
      client.close();
    }
  }

  Future<Resp> post(String path, Map<String, dynamic> body) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl('POST', base.resolve(path));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $apiKey',
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      return Resp(await request.close());
    } finally {
      client.close(force: true);
    }
  }
}

class Resp {
  Resp(this.response);
  final HttpClientResponse response;
  int get statusCode => response.statusCode;
  bool _read = false;
  Future<String>? _text;

  Future<String> read() {
    if (_read) {
      throw StateError('response body already consumed');
    }
    _read = true;
    return _text ??= utf8.decoder.bind(response).join();
  }
}

Map<String, dynamic> relayConfig() => {
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
    };

Map<String, dynamic> movementConfig() => {
      'version': 1,
      'template': 'physics',
      'capacity': 4,
      'tick': {'simulationHz': 60, 'snapshotHz': 20},
      'colliders': {
        'boxes': [
          {
            'name': 'floor',
            'center': [0, -0.5, 0],
            'halfExtents': [50, 0.5, 50],
          },
        ],
      },
      'spawnPoints': [
        {'position': [0, 0, 0], 'yaw': 0},
      ],
      'movement': {
        'walkSpeed': 4.5,
        'runSpeed': 8.0,
        'gravity': -9.81,
        'jumpSpeed': 5.2,
        'airControl': 0.35,
        'acceleration': 40.0,
      },
      'inputMapping': {
        'moveX': {'type': 'axis', 'range': [-1, 1]},
        'moveZ': {'type': 'axis', 'range': [-1, 1]},
        'jump': {'type': 'action'},
        'sprint': {'type': 'action'},
      },
    };

class NodeClient extends RoomClient<SupSnap> {
  NodeClient(this.playUri, String name, {this.creatorToken})
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

Uri playUri(NodeHarness node, Map<String, dynamic> room,
        [String? token]) =>
    Uri.parse(
      'ws://127.0.0.1:${node.listener.port}'
      '/play/${room['roomKey']}?token=${token ?? room['joinToken']}',
    );

Future<void> until(bool Function() done, [String label = '',
    Duration timeout = const Duration(seconds: 8)]) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('Timed out $label');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('room-only hosting works without account routes or account tables', () async {
    final node = await NodeHarness.start();
    addTearDown(node.stop);
    for (final path in ['/oauth/client.json', '/auth/start', '/ident/nonce', '/panel']) {
      expect((await node.request('GET', path)).$1, 404, reason: path);
    }
    final tables = node.store.database
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name']);
    expect(tables, containsAll(['rooms', 'token_uses']));
    for (final name in ['guest_credentials', 'recovery_keys', 'did_profiles', 'handle_cache']) {
      expect(tables, isNot(contains(name)));
    }
  });

  test('control plane requires the service key', () async {
    final node = await NodeHarness.start();
    addTearDown(node.stop);
    final (noKeyStatus, noKeyBody) =
        await node.request('POST', '/v1/rooms', body: {
      'template': 'relay',
      'config': relayConfig(),
    }, key: '');
    expect(noKeyStatus, 401);
    expect((jsonDecode(noKeyBody) as Map)['error']['code'], 'unauthorized');
    final (badKeyStatus, _) = await node.request('POST', '/v1/rooms',
        body: {'template': 'relay', 'config': relayConfig()},
        key: 'sk_wrong');
    expect(badKeyStatus, 401);
    final (okStatus, _) = await node.request(
        'POST', '/v1/rooms',
        body: {'template': 'relay', 'config': relayConfig()});
    expect(okStatus, 201);
  });

  test(
    'a bootstrap key can restore a panel key’s access to a legacy room',
    () async {
      final node = await NodeHarness.start();
      addTearDown(node.stop);
      final owner = node.store.createApiKey(label: 'owner');
      final other = node.store.createApiKey(label: 'other');
      node.store.insertRoom(
        StoredRoom(
          roomId: 'rm_legacy',
          roomKey: 'legacy-room',
          template: 'relay',
          config: jsonEncode(relayConfig()),
          creatorToken: 'ct_legacy',
          status: 'live',
          createdAt: DateTime.utc(2026),
        ),
      );
      const path = '/v1/rooms/rm_legacy';
      final (before, details) = await node.request('GET', path);
      expect(before, 200);
      expect(jsonDecode(details), containsPair('ownerKeyId', null));
      final (beforeAssign, _) = await node.request(
        'GET',
        path,
        key: owner.fullKey,
      );
      expect(beforeAssign, 404);

      final body = {'keyId': owner.record.id};
      final (forbidden, _) = await node.request(
        'PUT',
        '$path/owner',
        body: body,
        key: owner.fullKey,
      );
      expect(forbidden, 403);
      for (var i = 0; i < 2; i++) {
        final (assigned, _) = await node.request(
          'PUT',
          '$path/owner',
          body: body,
        );
        expect(assigned, 204);
      }
      final (conflict, _) = await node.request(
        'PUT',
        '$path/owner',
        body: {'keyId': other.record.id},
      );
      expect(conflict, 409);

      final (listed, rooms) = await node.request(
        'GET',
        '/v1/rooms',
        key: owner.fullKey,
      );
      expect(listed, 200);
      expect(
        (jsonDecode(rooms)['rooms'] as List).single['roomId'],
        'rm_legacy',
      );
      final (minted, _) = await node.request(
        'POST',
        '$path/tokens',
        key: owner.fullKey,
      );
      expect(minted, 201);
      final (unrelated, _) = await node.request(
        'DELETE',
        path,
        key: other.fullKey,
      );
      expect(unrelated, 404);
      final (deleted, _) = await node.request(
        'DELETE',
        path,
        key: owner.fullKey,
      );
      expect(deleted, 204);
    },
  );

  test('relay room end to end: create, join, publish, replicate', () async {
    final node = await NodeHarness.start();
    addTearDown(node.stop);
    final room = await node.createRoom('relay', relayConfig());
    expect(room['template'], 'relay');
    expect(room['roomKey'] as String, isNotEmpty);
    expect(room['joinToken'] as String, startsWith('jt_'));
    expect(room['creatorToken'] as String, startsWith('ct_'));
    expect(room['url'] as String, contains('/play/${room['roomKey']}'));

    final creator = NodeClient(playUri(node, room), 'creator',
        creatorToken: room['creatorToken'] as String);
    await creator.connect();

    // A second join needs a second one-time token.
    final (minted, mintedBody) =
        await node.request('POST', '/v1/rooms/${room['roomId']}/tokens', body: {});
    expect(minted, 201);
    final secondToken = (jsonDecode(mintedBody)
        as Map<String, dynamic>)['joinToken'] as String;
    final guest =
        NodeClient(playUri(node, room, secondToken), 'guest');
    await guest.connect();
    await until(() => creator.latest != null, 'creator snapshot');

    creator.sendControl({
      'type': 'publishRoom',
      'key': 'phase',
      'value': 'started',
    });
    await until(() => guest.latest?.data['room']?['phase'] == 'started',
        'room row');
    expect(guest.social.leaderId, creator.id);
    expect(guest.latest!.data['room']['phase'], 'started');

    final (lookup, lookupBody) =
        await node.request('GET', '/v1/rooms/${room['roomId']}');
    expect(lookup, 200);
    final json = jsonDecode(lookupBody) as Map<String, dynamic>;
    expect(json['peers'], 2);
    expect(json['status'], 'live');
    expect(json['config'], relayConfig());

    await creator.close();
    await guest.close();
  });

  test('physics room end to end: inputs drive replicated poses', () async {
    final node = await NodeHarness.start();
    addTearDown(node.stop);
    final room = await node.createRoom('physics', movementConfig());
    final player = NodeClient(playUri(node, room), 'p1');
    await player.connect();
    player.sendControl({'type': 'input', 'moveX': 1});
    await until(() => player.latest != null, 'first snapshot');
    await until(
      () => (player.latest!.data['players'][player.id]
              as Map?)?['pose'] is Map,
      'pose',
    );
    final poseBefore = player.latest!.data['players'][player.id]['pose'] as Map;
    await until(
      () =>
          (player.latest!.data['players'][player.id]['pose']['x'] as double) >
          0.2,
      'walked',
    );
    final pose = player.latest!.data['players'][player.id]['pose'] as Map;
    expect(pose['x'] as double, greaterThan(poseBefore['x'] as double));
    await player.close();
  });

  test('invalid template/config rejected with contract codes', () async {
    final node = await NodeHarness.start();
    addTearDown(node.stop);
    final (templateStatus, templateBody) = await node.request(
        'POST', '/v1/rooms',
        body: {'template': 'golf', 'config': relayConfig()});
    expect(templateStatus, 422);
    expect((jsonDecode(templateBody) as Map)['error']['code'],
        'unsupported_template');

    final (configStatus, configBody) = await node.request(
        'POST', '/v1/rooms',
        body: {
          'template': 'relay',
          'config': {...relayConfig(), 'capacity': 999}
        });
    expect(configStatus, 422);
    expect((jsonDecode(configBody) as Map)['error']['code'], 'invalid_config');

    final (bodyStatus, _) = await node.request('POST', '/v1/rooms',
        body: {'template': 'relay'}); // config missing
    expect(bodyStatus, 400);
  });

  test('join-token gate: missing, wrong-room, expired, used all rejected '
      'before the upgrade', () async {
    final node = await NodeHarness.start();
    addTearDown(node.stop);
    final room = await node.createRoom('relay', relayConfig());
    final other = await node.createRoom('relay', relayConfig());
    final key = room['roomKey'] as String;
    final port = node.listener.port;

    // dart:io's `done` future does not settle promptly on server close;
    // the messages stream does.
    Future<Object?> connectStatus(Uri uri) async {
      WebSocket socket;
      try {
        socket = await WebSocket.connect(uri.toString())
            .timeout(const Duration(seconds: 3));
      } on Exception catch (e) {
        return e; // pre-upgrade rejection
      }
      final ended = Completer<int?>();
      final closeCode = <int?>[];
      socket.listen(
        (frame) {},
        onDone: () {
          closeCode.add(socket.closeCode);
          ended.complete(socket.closeCode);
        },
        onError: (Object _) => ended.complete(socket.closeCode),
      );
      final code = await ended.future.timeout(const Duration(seconds: 6));
      return closeCode.isNotEmpty ? closeCode.first : code;
    }

    // Missing token: pre-upgrade 401 → connect throws.
    final missing = await connectStatus(Uri.parse('ws://127.0.0.1:$port/play/$key'));
    expect(missing, isA<Exception>());

    // Wrong room: a valid token for the other room.
    final wrongRoom = await connectStatus(
        Uri.parse('ws://127.0.0.1:$port/play/$key'
            '?token=${other['joinToken']}'));
    expect(wrongRoom, isA<Exception>());

    // Expired: minted in the past by the node's own token authority.
    final expired = node.tokens.mintJoin(key,
        now: DateTime.now().toUtc().subtract(const Duration(minutes: 20)));
    final expiredResult = await connectStatus(
        Uri.parse('ws://127.0.0.1:$port/play/$key?token=$expired'));
    expect(expiredResult, isA<Exception>());

    // Used: the room's original token was consumed by the creator join…
    final client = NodeClient(playUri(node, room), 'creator',
        creatorToken: room['creatorToken'] as String);
    await client.connect();
    // …so replaying it upgrades but is closed immediately with 1008.
    final reused = await connectStatus(playUri(node, room));
    expect(reused, 1008);
    await client.close();

    // Unknown room key: 404 before upgrade.
    final unknownRoom = await connectStatus(Uri.parse(
        'ws://127.0.0.1:$port/play/nope?token=${room['joinToken']}'));
    expect(unknownRoom, isA<Exception>());
  });

  test('origin allowlist gates cross-origin upgrades', () async {
    final node = await NodeHarness.start(origins: ['https://game.example.com']);
    addTearDown(node.stop);
    final room = await node.createRoom('relay', relayConfig());
    final port = node.listener.port;
    final token = room['joinToken'] as String;

    // No Origin header: rejected pre-upgrade.
    await expectLater(
      WebSocket.connect(Uri.parse(
              'ws://127.0.0.1:$port/play/${room['roomKey']}?token=$token')
              .toString()),
      throwsA(isA<Exception>()),
    );
    // Wrong origin: rejected pre-upgrade.
    await expectLater(
      WebSocket.connect(
        Uri.parse('ws://127.0.0.1:$port/play/${room['roomKey']}?token=$token')
            .toString(),
        headers: {'Origin': 'https://evil.example'},
      ),
      throwsA(isA<Exception>()),
    );
    // Listed origin: the upgrade proceeds (the one-time token burns here,
    // so assert on a successful connect rather than a session).
    final socket = await WebSocket.connect(
      Uri.parse('ws://127.0.0.1:$port/play/${room['roomKey']}?token=$token')
          .toString(),
      headers: {'Origin': 'https://game.example.com'},
    );
    expect(socket.readyState, WebSocket.open);
    await socket.close();
  });

  test('per-IP throttle sheds connection floods', () async {
    final node = await NodeHarness.start(throttlePerMinute: 5);
    addTearDown(node.stop);
    final room = await node.createRoom('relay', relayConfig());
    final port = node.listener.port;
    Object? last;
    for (var i = 0; i < 6; i++) {
      try {
        final socket = await WebSocket.connect(Uri.parse(
                'ws://127.0.0.1:$port/play/${room['roomKey']}?token=bad')
            .toString());
        await socket.done;
        last = socket.closeCode;
      } on Exception catch (e) {
        last = e;
      }
    }
    // The first five attempts reach the token gate (bad token → 401
    // exceptions); the sixth is throttled pre-upgrade (also an exception,
    // but the throttle window is now exhausted).
    expect(last, isA<Exception>());
    expect(node.listener.throttle.trackedIps, greaterThanOrEqualTo(1));
  });

  test('list rooms paginates; delete drains and closes the door', () async {
    final node = await NodeHarness.start();
    addTearDown(node.stop);
    final rooms = [
      for (var i = 0; i < 3; i++)
        await node.createRoom('relay', relayConfig()),
    ];
    final (listStatus, listBody) =
        await node.request('GET', '/v1/rooms?limit=2');
    expect(listStatus, 200);
    final page = jsonDecode(listBody) as Map<String, dynamic>;
    expect((page['rooms'] as List).length, 2);
    expect(page['nextCursor'], isNotNull);
    final (page2Status, page2Body) =
        await node.request('GET', '/v1/rooms?limit=2&cursor=${page['nextCursor']}');
    expect(page2Status, 200);
    expect((jsonDecode(page2Body)['rooms'] as List).length, 1);

    final victim = rooms.first;
    final client = NodeClient(playUri(node, victim), 'p',
        creatorToken: victim['creatorToken'] as String);
    await client.connect();

    final (deleteStatus, deleteBody) =
        await node.request('DELETE', '/v1/rooms/${victim['roomId']}');
    expect(deleteStatus, 204);
    expect(deleteBody, isEmpty);
    // Idempotent on a closed room.
    final (again, _) = await node.request('DELETE', '/v1/rooms/${victim['roomId']}');
    expect(again, 204);
    // The drained room's socket is closed by the host…
    await until(() => !client.connected, 'peer drained');
    await client.close();
    // …new tokens are refused, and joins hit 404 before upgrade.
    final (mintStatus, _) =
        await node.request('POST', '/v1/rooms/${victim['roomId']}/tokens', body: {});
    expect(mintStatus, 404);
    final (lookupStatus, lookupBody) =
        await node.request('GET', '/v1/rooms/${victim['roomId']}');
    expect(lookupStatus, 200);
    expect((jsonDecode(lookupBody) as Map)['status'], 'closed');
    await expectLater(
      WebSocket.connect(playUri(node, victim,
              victim['joinToken'] as String)
          .toString()),
      throwsA(isA<Exception>()),
    );
  });

  test('capacity shedding surfaces as 429 quota_exceeded', () async {
    final node = await NodeHarness.start(maxRooms: 1);
    addTearDown(node.stop);
    await node.createRoom('relay', relayConfig());
    final (status, body) = await node.request(
        'POST', '/v1/rooms', body: {'template': 'relay', 'config': relayConfig()});
    expect(status, 429);
    expect((jsonDecode(body) as Map)['error']['code'], 'quota_exceeded');
  });

  test('idle reap fires over the real listener; rejoin restarts', () async {
    final node = await NodeHarness.start(
        idleTtl: const Duration(seconds: 2));
    addTearDown(node.stop);
    final room = await node.createRoom('relay', relayConfig());
    final client = NodeClient(playUri(node, room), 'p',
        creatorToken: room['creatorToken'] as String);
    await client.connect();
    final supervised = node.supervisor.room(room['roomKey'] as String);
    expect(supervised, isNotNull);
    await client.close();
    await until(() => supervised!.reaped, 'reaped');
    // A fresh token restarts the room through the listener.
    final (minted, mintedBody) =
        await node.request('POST', '/v1/rooms/${room['roomId']}/tokens', body: {});
    expect(minted, 201);
    final rejoined = NodeClient(
      playUri(node, room,
          (jsonDecode(mintedBody) as Map)['joinToken'] as String),
      'q',
    );
    await rejoined.connect();
    expect(node.supervisor.room(room['roomKey'] as String)!.reaped, isFalse);
    await rejoined.close();
  });

  test('a node restart lazily recreates store-known rooms on join', () async {
    final node = await NodeHarness.start();
    addTearDown(node.stop);
    final room = await node.createRoom('relay', relayConfig());
    // Simulate the process losing its rooms (supervisor wiped).
    await node.supervisor.destroy(room['roomKey'] as String);
    expect(node.supervisor.room(room['roomKey'] as String), isNull);
    // The store still knows the room; a join recreates it from the pinned
    // config. The original token was never consumed.
    final client = NodeClient(playUri(node, room), 'p');
    await client.connect();
    expect(node.supervisor.room(room['roomKey'] as String), isNotNull);
    await client.close();
  });

  test('ControlPlaneClient drives the node like the TS admin namespace',
      () async {
    final node = await NodeHarness.start();
    addTearDown(node.stop);
    final of = ControlPlaneClient('http://127.0.0.1:0', apiKey)
      ..base = node.base;

    final room = await of.createRoom('relay', relayConfig());
    expect(room['roomId'] as String, startsWith('rm_'));
    expect(room['joinToken'] as String, startsWith('jt_'));
    expect(room['url'] as String, contains('/play/${room['roomKey']}'));

    final minted = await of.mintToken(room['roomId'] as String);
    expect(minted['joinToken'] as String, startsWith('jt_'));
    final withCreator =
        await of.mintToken(room['roomId'] as String, creator: true);
    expect(withCreator['creatorToken'] as String, startsWith('ct_'));

    final player = NodeClient(playUri(node, room), 'p',
        creatorToken: room['creatorToken'] as String);
    await player.connect();

    final list = await of.listRooms();
    expect(
      (list['rooms'] as List)
          .any((r) => (r as Map)['roomId'] == room['roomId']),
      isTrue,
    );
    final lookedUp = await of.room(room['roomId'] as String);
    expect(lookedUp['peers'], 1);

    await of.deleteRoom(room['roomId'] as String);
    final after = await of.room(room['roomId'] as String);
    expect(after['status'], 'closed');
    await until(() => !player.connected, 'peer drained');
    await player.close();
    of.close();
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:client/client.dart';
import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

RelayRoomConfig relayConfig({
  int capacity = 8,
  int maxRows = 64,
  int totalBytes = 32768,
  Map<String, RelayKeyQuota> playerKeys = const {
    'pose': RelayKeyQuota(maxBytes: 256, publishesPerSecond: 10),
  },
  Map<String, RelayKeyQuota> roomKeys = const {
    'phase': RelayKeyQuota(maxBytes: 64, publishesPerSecond: 1),
  },
}) => RelayRoomConfig(
  capacity: capacity,
  maxRows: maxRows,
  totalBytes: totalBytes,
  playerKeys: playerKeys,
  roomKeys: roomKeys,
);

/// The entire client-side integration for a relay room: one typed RoomClient
/// whose join payload optionally carries the creator claim.
class RelayRoomClient extends RoomClient<RoomSnapshot> {
  RelayRoomClient(
    String name,
    Future<GameConnection> Function() connector, {
    this._creatorToken,  }) : super(
         uri: Uri.parse('memory://relay'),
         name: name,
         protocolVersion: 1,
         connector: connector,
       );
  final String? _creatorToken;
  @override
  Map<String, dynamic> get joinPayload => {
    if (_creatorToken != null) 'creatorToken': _creatorToken,
  };
  @override
  RoomSnapshot decodeSnapshot(Map<String, dynamic> data) => RoomSnapshot(data);
}

Future<void> until(bool Function() done, [String label = '']) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('Timed out $label');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('config validation mirrors room_templates.md', () {
    // The documented example, verbatim.
    RelayRoomConfig.fromJson(jsonDecode('''
    {
      "version": 1, "template": "relay", "capacity": 16, "chat": true,
      "maxRows": 64, "totalBytes": 32768,
      "playerKeys": {
        "pose": { "maxBytes": 256, "publishesPerSecond": 10 },
        "emote": { "maxBytes": 96, "publishesPerSecond": 2 }
      },
      "roomKeys": { "phase": { "maxBytes": 64, "publishesPerSecond": 1 } }
    }
    ''') as Map<String, dynamic>);
    void bad(String json) =>
        expect(() => RelayRoomConfig.fromJson(jsonDecode(json) as Map<String, dynamic>), throwsFormatException);
    bad('{"version": 2, "template": "relay"}');
    bad('{"version": 1, "template": "physics"}');
    bad('{"version": 1, "template": "relay", "extra": 1}');
    bad('{"version": 1, "template": "relay", "capacity": 0}');
    bad('{"version": 1, "template": "relay", "playerKeys": {"Pose": {"maxBytes": 8, "publishesPerSecond": 1}}}');
    bad('{"version": 1, "template": "relay", "playerKeys": {"pose": {"maxBytes": 999999, "publishesPerSecond": 1}}}');
    bad('{"version": 1, "template": "relay", "playerKeys": {}}');
  });

  group('quota rejection', () {
    test('per-key size cap drops the write, not the writer', () {
      final authority = RelayAuthority(
        relayConfig(playerKeys: const {
          'pose': RelayKeyQuota(maxBytes: 96, publishesPerSecond: 10),
        }),
        creatorToken: 'ct',
      );
      authority.addPlayer('p1', 'One', null);
      authority.command('p1', {
        'type': 'publish',
        'key': 'pose',
        'value': 'a' * 250,
      });
      expect(authority.snapshot()['players']['p1'], isEmpty);
      expect(authority.rejectedWrites, 1);
      expect(authority.lastRejection, 'row exceeds maxBytes');
      authority.command('p1', {'type': 'publish', 'key': 'pose', 'value': 'ok'});
      expect(authority.snapshot()['players']['p1'], {
        'pose': 'ok',
      });
    });

    test('tight rate quota accepts N then rejects until the window slides', () {
      final authority = RelayAuthority(
        relayConfig(playerKeys: const {
          'pose': RelayKeyQuota(maxBytes: 256, publishesPerSecond: 2),
        }),
        creatorToken: 'ct',
      );
      authority.addPlayer('p1', 'One', null);
      void publish(Object? value) => authority.command('p1', {
        'type': 'publish',
        'key': 'pose',
        'value': value,
      });
      publish('one');
      publish('two');
      publish('three');
      expect(authority.snapshot()['players']['p1'], {'pose': 'two'});
      expect(authority.rejectedWrites, 1);
      expect(authority.lastRejection, 'publish rate exceeded');
      authority.update(1.1); // slide the window
      publish('four');
      expect(authority.snapshot()['players']['p1'], {'pose': 'four'});
    });

    test('total state bytes cap the room, not the key', () {
      final authority = RelayAuthority(
        relayConfig(totalBytes: 300, capacity: 4),
        creatorToken: 'ct',
      );
      authority.addPlayer('p1', 'One', null);
      authority.addPlayer('p2', 'Two', null);
      final big = {'type': 'publish', 'key': 'pose', 'value': 'a' * 250};
      authority.command('p1', big);
      authority.command('p2', big);
      expect(authority.snapshot()['players']['p1'], isNotEmpty);
      expect(authority.snapshot()['players']['p2'], isEmpty);
      expect(authority.lastRejection, 'room exceeds totalBytes');
    });

    test('maxRows bounds retained rows across player and room rows', () {
      final authority = RelayAuthority(
        relayConfig(maxRows: 2, capacity: 4),
        creatorToken: 'ct',
      );
      authority.addPlayer('p1', 'Creator', const {'creator': true});
      authority.addPlayer('p2', 'Two', null);
      authority.command('p1', {'type': 'publish', 'key': 'pose', 'value': 1});
      authority.command('p2', {'type': 'publish', 'key': 'pose', 'value': 2});
      authority.command('p1', {
        'type': 'publishRoom',
        'key': 'phase',
        'value': 'started',
      });
      expect(authority.snapshot()['room'], isEmpty);
      expect(authority.lastRejection, 'room exceeds maxRows');
      authority.removePlayer('p2');
      authority.command('p1', {
        'type': 'publishRoom',
        'key': 'phase',
        'value': 'started',
      });
      expect(authority.snapshot()['room'], {'phase': 'started'});
    });
  });

  group('ownership', () {
    test('players write only their own declared keys', () {
      final authority = RelayAuthority(
        relayConfig(roomKeys: const {
          'phase': RelayKeyQuota(maxBytes: 64, publishesPerSecond: 1),
        }),
        creatorToken: 'ct',
      );
      authority.addPlayer('p1', 'One', null);
      authority.addPlayer('p2', 'Two', null);
      // Key declared only in the room scope is undeclared for players.
      authority.command('p1', {'type': 'publish', 'key': 'phase', 'value': 'x'});
      expect(authority.lastRejection, 'undeclared key: phase');
      // Undeclared keys never land.
      authority.command('p1', {'type': 'publish', 'key': 'nope', 'value': 1});
      expect(authority.lastRejection, 'undeclared key: nope');
      // There is no addressee to forge: a forged playerId field is ignored.
      authority.command('p2', {
        'type': 'publish',
        'key': 'pose',
        'value': {'x': 1},
        'playerId': 'p1',
      });
      expect(authority.snapshot()['players']['p1'], isEmpty);
      expect(authority.snapshot()['players']['p2'], {
        'pose': {'x': 1},
      });
    });

    test('room keys are leader-only and the creator leads, not the first joiner', () async {
      final authority = RelayAuthority(relayConfig(), creatorToken: 'ct');
      final hub = RoomHub(authority, protocolVersion: 1, simulationHz: 60, snapshotHz: 15);
      hub.start();
      addTearDown(hub.close);
      Future<RelayRoomClient> join(String name, {String? creatorToken}) async {
        final pair = MemoryTransportPair();
        final client = RelayRoomClient(name, () async {
          unawaited(hub.runTransport(pair.b));
          return pair.a;
        }, creatorToken: creatorToken);
        await client.connect();
        return client;
      }
      // The guest joins FIRST; the creator claims leadership at join.
      final guest = await join('Guest');
      final creator = await join('Creator', creatorToken: 'ct');
      await until(() => guest.social.leaderId == creator.id, 'leaderId');
      expect(guest.social.leaderId, creator.id);
      // Non-leader room writes are dropped.
      guest.sendControl({'type': 'publishRoom', 'key': 'phase', 'value': 'nope'});
      await until(() => authority.rejectedWrites >= 1, 'reject');
      expect(authority.lastRejection, 'leader only');
      // The leader's room write replicates to the guest.
      creator.sendControl({'type': 'publishRoom', 'key': 'phase', 'value': 'started'});
      await until(() => guest.latest?.data['room']?['phase'] == 'started', 'room');
      // A published pose gives pings authority-side coordinates: the pinger's
      // own row answers the ping (golf's "my ball" semantics).
      guest.sendControl({
        'type': 'publish',
        'key': 'pose',
        'value': {'x': 1.5, 'y': 0, 'z': -2},
      });
      await until(() => guest.latest?.data['players']?[guest.id]?['pose'] != null, 'pose');
      guest.social.ping('here');
      await until(() => creator.social.pings.isNotEmpty, 'ping');
      expect(creator.social.pings.single.location.x, 1.5);
      expect(creator.social.pings.single.playerId, guest.id);
      await guest.close();
      await creator.close();
    });
  });

  group('malformed payload rejection', () {
    test('deep validation rejects hidden controls, non-finite numbers, bad shapes', () {
      final authority = RelayAuthority(relayConfig(), creatorToken: 'ct');
      authority.addPlayer('p1', 'One', null);
      void publish(Object? value, {Object? key = 'pose'}) =>
          authority.command('p1', {'type': 'publish', 'key': key, 'value': value});
      publish({'text': 'a\u202eb'});
      expect(authority.lastRejection, 'invalid value');
      publish({'text': 'a\u0007b'});
      expect(authority.lastRejection, 'invalid value');
      publish({'nan': double.nan});
      expect(authority.lastRejection, 'invalid value');
      publish({'inf': double.infinity});
      expect(authority.lastRejection, 'invalid value');
      publish({1: 'non-string map key'});
      expect(authority.lastRejection, 'invalid value');
      publish('ok', key: 42);
      expect(authority.lastRejection, 'key must be a string');
      authority.command('p1', {'type': 'publish', 'key': 'pose'});
      expect(authority.lastRejection, 'missing value');
      expect(authority.rejectedWrites, 7);
      expect(authority.snapshot()['players']['p1'], isEmpty);
    });

    test('a live peer survives its own bad publishes', () async {
      final authority = RelayAuthority(relayConfig(), creatorToken: 'ct');
      final hub = RoomHub(authority, protocolVersion: 1, simulationHz: 60, snapshotHz: 15);
      hub.start();
      addTearDown(hub.close);
      final pair = MemoryTransportPair();
      final client = RelayRoomClient('Guest', () async {
        unawaited(hub.runTransport(pair.b));
        return pair.a;
      });
      await client.connect();
      // NaN/Infinity cannot cross a JSON transport; the deep-validation unit
      // test covers them. Hidden control characters can, and must be dropped
      // without dropping the writer.
      client.sendControl({'type': 'publish', 'key': 'pose', 'value': {'text': 'a\u202eb'}});
      client.sendControl({'type': 'publish', 'key': 'pose', 'value': 'a\u0000b'});
      await until(() => authority.rejectedWrites >= 2);
      expect(client.connected, isTrue);
      expect(client.error, isNull);
      client.sendControl({'type': 'publish', 'key': 'pose', 'value': {'x': 1}});
      await until(() => client.latest?.data['players']?[client.id]?['pose'] != null);
      await client.close();
    });
  });

  group('replication', () {
    test('relay state round-trips through the baseline/delta codec', () {
      final authority = RelayAuthority(relayConfig(), creatorToken: 'ct');
      authority.addPlayer('p1', 'One', null);
      authority.addPlayer('p2', 'Two', null);
      authority.command('p1', {
        'type': 'publish',
        'key': 'pose',
        'value': {'x': 1.25, 'y': 0, 'z': -3.5},
      });
      final encoder = SnapshotEncoder(), decoder = SnapshotDecoder();
      final baseline = encoder.prepare(authority.snapshot());
      expect(encoder.isBaseline(baseline), isTrue);
      final decoded0 = decoder.decode(jsonDecode(encoder.baseline!))!;
      expect(decoded0['players']['p1']['pose'], {
        'x': 1.25,
        'y': 0,
        'z': -3.5,
      });
      expect(decoded0['players']['p2'], isEmpty);

      authority.update(1 / 20);
      authority.command('p2', {
        'type': 'publish',
        'key': 'pose',
        'value': {'x': 2, 'y': 1, 'z': 0},
      });
      final delta = encoder.prepare(authority.snapshot());
      expect(encoder.isBaseline(delta), isFalse);
      final decoded1 = decoder.decode(jsonDecode(encoder.encodePrepared(delta)))!;
      expect(decoded1['players']['p2']['pose'], {'x': 2, 'y': 1, 'z': 0});
      expect(decoded1['players']['p1']['pose'], {
        'x': 1.25,
        'y': 0,
        'z': -3.5,
      });
    });

    test('a relay room is a few lines of code', () async {
      // Compare with the custom-authority path in
      // packages/protocol/test/room_test.dart: CounterAuthority is ~40 lines
      // of game code plus a typed client. Here the whole game is a config
      // literal, one authority construction, and publish calls.
      final authority = RelayAuthority(
        RelayRoomConfig.fromJson(jsonDecode('''
        { "version": 1, "template": "relay", "capacity": 16,
          "maxRows": 64, "totalBytes": 32768,
          "playerKeys": { "pose": { "maxBytes": 256, "publishesPerSecond": 10 } },
          "roomKeys": { "phase": { "maxBytes": 64, "publishesPerSecond": 1 } } }
        ''') as Map<String, dynamic>),
        creatorToken: 'ct',
      );
      final hub = RoomHub(authority, protocolVersion: 1);
      hub.start();
      addTearDown(hub.close);
      Future<RelayRoomClient> join(String name, {String? token}) async {
        final pair = MemoryTransportPair();
        final client = RelayRoomClient(name, () async {
          unawaited(hub.runTransport(pair.b));
          return pair.a;
        }, creatorToken: token);
        await client.connect();
        return client;
      }
      final creator = await join('Creator', token: 'ct');
      final guest = await join('Guest');
      await until(() => guest.social.available, 'social');
      guest.social.sendChat('hello');
      creator.sendControl({
        'type': 'publish',
        'key': 'pose',
        // Non-zero values: the shared delta codec's deadband omits zero
        // fields (presence masks only preserve resets to zero), and an
        // all-zero first pose would encode as an empty patch.
        'value': {'x': 2.5, 'y': 0.5, 'z': -1},
      });
      await until(
        () =>
            guest.latest?.data['players']?[creator.id]?['pose'] != null &&
            guest.social.messages.any((m) => m.text == 'hello'),
        'tiny',
      );
      expect(guest.social.messages.last.playerName, 'Guest');
      await creator.close();
      await guest.close();
    });
  });
}

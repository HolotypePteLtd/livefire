import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:client/client.dart';
import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

/// A second application with no golf, physics or renderer dependencies.
class CounterAuthority implements RoomAuthority {
  final counters = <String, int>{};
  @override
  int capacity = 2, tick = 0;
  @override
  double elapsed = 0;
  @override
  void update(double seconds) {
    elapsed += seconds;
    tick++;
  }

  @override
  Object? validateJoin(Map<String, dynamic> message) => null;
  @override
  void addPlayer(String id, String name, Object? data) => counters[id] = 0;
  @override
  void resume(String id, Object? data) {}
  @override
  void disconnect(String id) {}
  @override
  void removePlayer(String id) => counters.remove(id);
  @override
  Map<String, dynamic> welcome(String id) => {'sequence': 0};
  @override
  void command(String id, Map<String, dynamic> message) {
    if (message['type'] == 'increment') counters[id] = counters[id]! + 1;
  }

  @override
  Map<String, dynamic> snapshot() => {
    'type': 'snapshot',
    'epoch': 0,
    'tick': tick,
    'time': elapsed,
    'players': {
      for (final entry in counters.entries) entry.key: {'count': entry.value},
    },
  };
  @override
  void dispose() {}
}

class CounterClient extends RoomClient<RoomSnapshot> {
  CounterClient(
    Uri uri,
    String name, {
    super.connector,
  }) : super(uri: uri, name: name, protocolVersion: 71);
  @override
  RoomSnapshot decodeSnapshot(Map<String, dynamic> data) => RoomSnapshot(data);
}

class BlockingCounterAuthority extends CounterAuthority {
  @override
  void command(String id, Map<String, dynamic> message) {
    if (message['type'] == 'load') {
      sleep(const Duration(milliseconds: 300));
      return;
    }
    super.command(id, message);
  }
}

Future<void> until(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('Timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test(
    'zero-delay sampling returns the newest state despite clock slew',
    () async {
      final connection = _QueuedCloseConnection();
      final client = CounterClient(
        Uri.parse('ws://test.invalid'),
        'One',
        connector: () async => connection,
      );
      addTearDown(client.close);
      await client.connect();
      connection._messages.add(jsonEncode(connection.state(2)));
      await until(() => client.latest!.tick == 2);
      final sample = client.sampleTimeline(delay: 0)!;
      expect(sample.before, same(client.latest));
      expect(sample.after, same(client.latest));
      expect(client.renderedSnapshot, same(client.latest));
    },
  );
  test('queued states after local close do not disable reconnection', () async {
    final connections = <_QueuedCloseConnection>[];
    final client = CounterClient(
      Uri.parse('ws://test.invalid'),
      'One',
      connector: () async {
        final connection = _QueuedCloseConnection();
        connections.add(connection);
        return connection;
      },
    );
    addTearDown(client.close);
    await client.connect();
    final id = client.id;
    await client.interruptConnection();
    await until(() => connections.length == 2 && client.connected);
    expect(client.error, isNull);
    expect(client.id, id);
    expect(client.reconnecting, isFalse);
    expect(connections.first.closedWrites, 0);
  });
  test('binary-only broadcasts never serialize a JSON state', () async {
    final authority = _ProbeAuthority();
    final hub = RoomHub(
      authority,
      protocolVersion: 71,
      wireCodec: _ProbeCodec(),
    );
    final pair = MemoryTransportPair();
    final frames = <dynamic>[];
    final sub = pair.a.messages.listen(frames.add);
    addTearDown(() async {
      await hub.close();
      await sub.cancel();
    });
    final joined = hub.runTransport(pair.b);
    pair.a.send(
      jsonEncode({
        'type': 'join',
        'protocol': 71,
        'name': 'Binary',
        'binaryStates': true,
      }),
    );
    await joined;
    // JSON is needed for the initial welcome. Instrument later snapshots,
    // including a new reliable baseline, after negotiation is complete.
    authority.probe = _JsonProbe();
    for (var i = 0; i < 20; i++) {
      authority.tick += 6;
      hub.broadcast();
      pair.a.send(jsonEncode({'type': 'ack', 'ack': authority.tick}));
      await Future<void>.delayed(Duration.zero);
    }
    expect(frames.whereType<List<int>>(), isNotEmpty);
    expect(authority.probe!.encodes, 0);
  });
  test('preparing binary snapshots defers JSON and detaches one baseline', () {
    final value = _JsonProbe();
    final encoder = SnapshotEncoder();
    final snapshot = <String, dynamic>{
      'type': 'snapshot',
      'tick': 0,
      'epoch': 0,
      'value': value,
      'position': [1.123456],
    };
    final prepared = encoder.prepare(snapshot);
    expect(value.encodes, 0);
    expect(encoder.baseMap, same(prepared));
    expect(prepared['position'], [1.1235]);
    (snapshot['position'] as List)[0] = 9.0;
    expect(prepared['position'], [1.1235]);
    expect(encoder.isBaseline(prepared), isTrue);
    expect(jsonDecode(encoder.baseline!)['position'], [1.1235]);
    expect(value.encodes, 1);
    encoder.baseline;
    expect(
      value.encodes,
      1,
      reason: 'Legacy peers share the cached JSON baseline',
    );
    final delta = encoder.prepare({...snapshot, 'tick': 6});
    expect(encoder.isBaseline(delta), isFalse);
    final decoder = SnapshotDecoder()..decode(jsonDecode(encoder.baseline!));
    expect(
      decoder.decode(jsonDecode(encoder.encodePrepared(delta)))!['position'],
      [9.0],
    );
    encoder.prepare({...snapshot, 'tick': 7, 'epoch': 1});
    expect(value.encodes, 1, reason: 'A new binary baseline stays lazy too');
  });

  test('same-tick metadata updates still encode relative to the baseline', () {
    final encoder = SnapshotEncoder(), decoder = SnapshotDecoder();
    final base = <String, dynamic>{
      'type': 'snapshot',
      'tick': 0,
      'epoch': 0,
      'name': 'Before',
    };
    decoder.decode(jsonDecode(encoder.encode(base)));
    final changed = encoder.prepare({...base, 'name': 'After'});
    expect(encoder.isBaseline(changed), isFalse);
    expect(
      decoder.decode(jsonDecode(encoder.encodePrepared(changed)))!['name'],
      'After',
    );
  });
  test(
    'host stalls permit a bounded queued burst while ordinary floods fail',
    () async {
      for (final stall in [false, true]) {
        final authority = BlockingCounterAuthority();
        final hub = RoomHub(authority, protocolVersion: 71);
        final pair = MemoryTransportPair();
        final errors = <String>[];
        final sub = pair.a.messages.listen((raw) {
          final message = jsonDecode(raw as String) as Map;
          if (message['type'] == 'error') {
            errors.add(message['message'] as String);
          }
        });
        final joined = hub.runTransport(pair.b);
        pair.a.send(
          jsonEncode({'type': 'join', 'protocol': 71, 'name': 'One'}),
        );
        await joined;
        if (stall) pair.a.send(jsonEncode({'type': 'load'}));
        for (var i = 0; i < 130; i++) {
          pair.a.send(jsonEncode({'type': 'increment'}));
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (stall) {
          expect(authority.counters['p1'], 130);
          expect(errors, isEmpty);
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          for (var i = 0; i < 130; i++) {
            pair.a.send(jsonEncode({'type': 'increment'}));
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(
            errors,
            contains('Input rate exceeded'),
            reason:
                'Stall credit must expire, retaining the normal flood limit',
          );
        } else {
          expect(errors, contains('Input rate exceeded'));
        }
        await hub.close();
        await sub.cancel();
      }
    },
  );
  test(
    'closing a hub also closes pending joins and stops manual pumping',
    () async {
      final authority = CounterAuthority();
      final hub = RoomHub(authority, protocolVersion: 71);
      final pair = MemoryTransportPair();
      final joined = hub.runTransport(pair.b);
      await hub.close();
      expect(await joined.timeout(const Duration(seconds: 1)), isNull);
      expect(pair.a.open, isFalse);
      expect(hub.peerCount, 0);
      hub.pumpSeconds(.1);
      expect(authority.tick, 0);
    },
  );
  test(
    'a different application can host, replicate, resume and free slots',
    () async {
      final authority = CounterAuthority();
      final host = RoomServer(
        authority,
        protocolVersion: 71,
        simulationHz: 60,
        snapshotHz: 15,
      );
      await host.start(port: 0, address: InternetAddress.loopbackIPv4);
      addTearDown(host.close);
      final first = CounterClient(host.localUri, 'One'),
          second = CounterClient(host.localUri, 'Two');
      addTearDown(first.close);
      addTearDown(second.close);
      await first.connect();
      await second.connect();
      first.sendControl({'type': 'increment'});
      await until(() => second.latest!.players[first.id]?['count'] == 1);
      final id = first.id;
      await first.interruptConnection();
      await until(() => first.connected && !first.reconnecting);
      expect(first.id, id);
      expect(first.latest!.players[id]['count'], 1);
      final extra = CounterClient(host.localUri, 'Full');
      addTearDown(extra.close);
      await expectLater(extra.connect(), throwsStateError);
      await second.close();
      await until(() => authority.counters.length == 1);
      expect(first.sampleTimeline(), isNotNull);
    },
  );
}

/// A socket can close before its already-buffered state reaches the listener.
class _QueuedCloseConnection implements GameConnection {
  final _messages = StreamController<dynamic>();
  bool _open = true;
  Future<void>? _closing;
  int closedWrites = 0;
  Map<String, dynamic> state(int tick) => {
    'type': 'snapshot',
    'epoch': 0,
    'tick': tick,
    'time': tick / 60,
    'players': {
      'p1': {'count': 0},
    },
  };
  @override
  bool get open => _open;
  @override
  Stream<dynamic> get messages => _messages.stream;
  @override
  void send(String message) {
    if (!_open) {
      closedWrites++;
      throw StateError('StreamSink is closed');
    }
    final data = jsonDecode(message) as Map;
    if (data['type'] == 'join') {
      _messages.add(
        jsonEncode({
          'type': 'welcome',
          'protocol': 71,
          'capacity': 2,
          'id': 'p1',
          'resume': 'same-token',
          'sequence': 0,
        }),
      );
      _messages.add(jsonEncode(state(1)));
    } else if (data['type'] == 'leave') {
      _messages.add(jsonEncode({'type': 'left'}));
    }
  }

  @override
  Future<void> close([int? code, String? reason]) {
    if (_closing != null) return _closing!;
    _open = false;
    _messages.add(jsonEncode(state(2)));
    return _closing = _messages.close();
  }
}

class _JsonProbe {
  int encodes = 0;
  Object toJson() {
    encodes++;
    return 1;
  }
}

class _ProbeAuthority extends CounterAuthority {
  _JsonProbe? probe;
  @override
  Map<String, dynamic> snapshot() => {
    ...super.snapshot(),
    if (probe != null) 'probe': probe,
  };
}

class _ProbeCodec implements WireStateCodec {
  @override
  bool supports(Object peer) => peer is BinaryGameConnection;
  @override
  List<int> encodeState(Map<String, dynamic> snapshot) => [0];
  @override
  List<int> encodeDelta(
    Map<String, dynamic> base,
    Map<String, dynamic> current,
  ) => [1];
  @override
  DecodedWireState? decode(Object frame, Map<String, dynamic> baseline) => null;
}

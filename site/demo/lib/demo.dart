// The demo engine — the counter-example room from `examples/counter`
// rebuilt for the browser: one RoomHub + CounterAuthority (the server half)
// and RoomClients (the player half) all inside the visitor's tab, joined
// through in-memory transports instead of sockets.
//
// This library is deliberately platform-free: the web entry (web/main.dart)
// only renders it, and test/demo_test.dart drives the exact same code on
// the Dart VM to prove the sequence headlessly.
import 'dart:async';

import 'package:client/client.dart';

/// Applications pick their own protocol version; client and server must match.
const protocolVersion = 1;

/// Everything the demo UI (and the headless test) observes.
sealed class DemoEvent {
  const DemoEvent();
}

/// A player completed the join handshake and is on the roster.
class PlayerJoined extends DemoEvent {
  const PlayerJoined(this.name, this.peerId);
  final String name, peerId;
}

/// A chat line arrived (scripted or from the visitor).
class ChatLine extends DemoEvent {
  const ChatLine(this.from, this.text);
  final String from, text;
}

/// A replicated snapshot: per-player counter values, by display name.
class CounterState extends DemoEvent {
  const CounterState(this.counts, this.tick);
  final Map<String, int> counts;
  final int tick;
}

/// A status message from the demo room.
class DemoNote extends DemoEvent {
  const DemoNote(this.text);
  final String text;
}

/// The whole game: a per-player counter incremented by 'increment'
/// commands — identical to `examples/counter/bin/counter.dart`.
class CounterAuthority implements RoomAuthority {
  final counters = <String, int>{};
  @override
  int capacity = 8, tick = 0;
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
      for (final entry in counters.entries)
        entry.key: {'count': entry.value},
    },
  };
  @override
  void dispose() {}
}

/// A concrete client: snapshots decode into [RoomSnapshot]; the base class
/// handles join, resume, acks, reconnection and the social lane.
class _DemoClient extends RoomClient<RoomSnapshot> {
  _DemoClient(Uri uri, String name, MemoryTransport transport)
    : super(
        uri: uri,
        name: name,
        protocolVersion: protocolVersion,
        connector: () async => transport,
      );
  @override
  RoomSnapshot decodeSnapshot(Map<String, dynamic> data) =>
      RoomSnapshot(data);
}

/// A demo room: the server half (hub + authority) plus players joined via
/// [MemoryTransportPair]. Two scripted players (Alice and Bob) join on
/// [start] and keep the room alive with a chat/increment loop; the visitor
/// joins as a third player on first interaction.
class DemoRoom {
  DemoRoom({
    int simulationHz = 20,
    int snapshotHz = 10,
    this.scriptInterval = const Duration(seconds: 5),
  }) : hub = RoomHub(
         CounterAuthority(),
         protocolVersion: protocolVersion,
         simulationHz: simulationHz,
         snapshotHz: snapshotHz,
         roomKey: 'browser-demo',
       );

  final RoomHub hub;
  final Duration scriptInterval;

  final _events = StreamController<DemoEvent>.broadcast();
  Stream<DemoEvent> get events => _events.stream;

  final _clients = <String, RoomClient<RoomSnapshot>>{};
  final _names = <String, String>{}; // peer id -> display name
  RoomClient<RoomSnapshot>? _observer; // sees every chat and snapshot
  Timer? _script;
  int _beat = 0, _seenChat = 0;
  bool _closed = false;

  /// Starts the engine and the scripted players.
  Future<void> start() async {
    if (_closed) return;
    hub.start();
    _emit(const DemoNote('Room opened'));
    await _joinScripted('Alice');
    await _joinScripted('Bob');
    _script = Timer.periodic(scriptInterval, (_) => _beatStep());
  }

  /// The visitor joins on first interaction (a third real player).
  Future<RoomClient<RoomSnapshot>> _ensureVisitor() async {
    final existing = _clients['You'];
    if (existing != null) return existing;
    return _joinScripted('You');
  }

  /// Sends one chat line as the visitor. Empty/unclean text returns false.
  Future<bool> visitorSay(String text) async {
    if (_closed || text.trim().isEmpty) return false;
    final you = await _ensureVisitor();
    return you.social.sendChat(text);
  }

  /// Increments the counter as the visitor.
  Future<void> visitorIncrement() async {
    if (_closed) return;
    final you = await _ensureVisitor();
    you.sendControl({'type': 'increment'});
  }

  /// The bots alternate increments and announce their first point in chat.
  void _beatStep() {
    final name = _beat++ % 2 == 0 ? 'Bob' : 'Alice';
    final player = _clients[name];
    player?.sendControl({'type': 'increment'});
    if (_beat <= 2) player?.social.sendChat('+1');
  }

  Future<RoomClient<RoomSnapshot>> _joinScripted(String name) async {
    final pair = MemoryTransportPair();
    unawaited(hub.runTransport(pair.a));
    final client = _DemoClient(Uri.parse('memory://browser-demo'), name, pair.b);
    await client.connect();
    await _until(() => client.social.available, '$name join handshake');
    _clients[name] = client;
    _names[client.id!] = name;
    _observer ??= client;
    client.onChanged = _observerTick;
    _emit(PlayerJoined(name, client.id!));
    return client;
  }

  /// The observer client repaints: diff the chat tail and the snapshot.
  void _observerTick() {
    final observer = _observer;
    if (observer == null) return;
    final messages = observer.social.messages;
    while (_seenChat < messages.length) {
      final m = messages[_seenChat++];
      if (!m.system) _emit(ChatLine(m.playerName, m.text));
    }
    final latest = observer.latest;
    if (latest != null) {
      final counts = <String, int>{};
      latest.players.forEach((id, row) {
        final name = _names[id] ?? id;
        counts[name] = (row['count'] as num?)?.toInt() ?? 0;
      });
      _emit(CounterState(counts, latest.tick));
    }
  }

  void _emit(DemoEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Stops the script, closes every client and the hub.
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _script?.cancel();
    for (final client in _clients.values) {
      await client.close();
    }
    await hub.close();
    await _events.close();
  }

  Future<void> _until(bool Function() done, String what) async {
    final end = DateTime.now().add(const Duration(seconds: 8));
    while (!done()) {
      if (DateTime.now().isAfter(end)) {
        throw StateError('Timed out waiting for: $what');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

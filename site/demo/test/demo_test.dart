// Headless proof that the demo engine actually works: the same DemoRoom
// the browser runs, driven on the Dart VM. Verifies the join handshake,
// scripted chat, scripted increments, snapshot replication and the
// visitor's own chat + increment — the sequence a human sees rendered.
import 'dart:async';

import 'package:test/test.dart';

import 'package:rooms_demo/demo.dart';

Future<void> until(bool Function() done, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('Timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('scripted players join, chat and increment; the visitor too', () async {
    final room = DemoRoom(scriptInterval: const Duration(milliseconds: 150));
    final log = <DemoEvent>[];
    final sub = room.events.listen(log.add);
    addTearDown(sub.cancel);

    await room.start();

    // Join handshake: both scripted players on the roster.
    await until(
      () =>
          log.whereType<PlayerJoined>().map((e) => e.name).toSet().containsAll(
            ['Alice', 'Bob'],
          ),
      'Alice and Bob join',
    );
    final joined = log.whereType<PlayerJoined>().toList();
    expect(joined.length, 2);
    expect(joined.map((e) => e.peerId), everyElement(matches(RegExp(r'^p\d+$'))));

    // Scripted chat lines arrive (from both players).
    await until(
      () => log.any((e) => e is ChatLine && e.from == 'Alice'),
      'a chat line from Alice',
    );
    await until(
      () => log.any((e) => e is ChatLine && e.from == 'Bob'),
      'a chat line from Bob',
    );

    // Scripted increments replicate through snapshots to the observer.
    await until(
      () => log
          .whereType<CounterState>()
          .any((s) => (s.counts['Bob'] ?? 0) >= 1),
      'Bob count >= 1',
    );
    await until(
      () => log
          .whereType<CounterState>()
          .any((s) => (s.counts['Alice'] ?? 0) >= 1),
      'Alice count >= 1',
    );

    // The visitor joins on first interaction, increments, and chats.
    await room.visitorIncrement();
    await until(
      () => log.any((e) => e is PlayerJoined && e.name == 'You'),
      'visitor join handshake',
    );
    await until(
      () => log.whereType<CounterState>().any((s) => (s.counts['You'] ?? 0) >= 1),
      'visitor count >= 1',
    );

    expect(await room.visitorSay('  '), isFalse, reason: 'blank chat refused');
    expect(await room.visitorSay('hello from the test'), isTrue);
    await until(
      () => log.any((e) => e is ChatLine && e.from == 'You' && e.text == 'hello from the test'),
      'visitor chat line replicates',
    );

    // Every state event carries the whole room, ticks advance.
    final state = log.whereType<CounterState>().last;
    expect(state.counts.keys.toSet(), containsAll(['Alice', 'Bob', 'You']));
    expect(state.tick, greaterThan(0));

    await room.dispose();
    expect(room.hub.isClosed, isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));
}

// Unit tests for the world demo's kinematic authority: the anti-cheat
// contract (inputs are requests — clamped speed, bounded area) and
// multi-player behavior. Runs on the plain Dart VM.
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:world_demo/kinematic_world.dart';

void main() {
  test('input magnitude is clamped: no speed hack', () {
    final world = KinematicWorldAuthority();
    world.addPlayer('p1', 'A', null);
    // Ask for 3000x walking speed.
    world.command('p1', {'type': 'input', 'moveX': 3000, 'moveZ': 4000});
    for (var i = 0; i < 200; i++) {
      world.update(0.05);
    }
    final p = world.snapshot()['players']['p1'] as Map<String, dynamic>;
    final x = (p['x'] as num).toDouble();
    final z = (p['z'] as num).toDouble();
    // 10 simulated seconds at run speed 8: at most 80 m of travel.
    expect(math.sqrt(x * x + z * z), lessThan(80));
  });

  test('run is faster than walk, both bounded', () {
    final walk = _travel(KinematicWorldAuthority(), run: false);
    final run = _travel(KinematicWorldAuthority(), run: true);
    expect(run, greaterThan(walk));
    // 2 simulated seconds from a standing start; the acceleration ramp
    // costs v^2/(2a) of distance (plus fixed-step quantization).
    expect(walk, closeTo(4.5 * 2 - 4.5 * 4.5 / 60, 0.75));
    expect(run, closeTo(8 * 2 - 8 * 8 / 60, 1.2));
  });

  test('the area is bounded: avatar stops at the wall, not beyond', () {
    final world = KinematicWorldAuthority(halfExtent: 18);
    world.addPlayer('p1', 'A', null);
    world.command('p1', {'type': 'input', 'moveX': 1, 'run': true});
    for (var i = 0; i < 600; i++) {
      world.update(0.05); // 30 simulated seconds — plenty to cross.
    }
    final p = world.snapshot()['players']['p1'] as Map<String, dynamic>;
    expect((p['x'] as num).toDouble(), closeTo(18, 1e-9));
    expect((p['z'] as num).toDouble(), closeTo(0, 1e-9));
  });

  test('garbage input is ignored, finite input accepted', () {
    final world = KinematicWorldAuthority();
    world.addPlayer('p1', 'A', null);
    final spawn = world.welcome('p1')['spawn'] as Map<String, dynamic>;
    final sx = (spawn['x'] as num).toDouble();
    final sz = (spawn['z'] as num).toDouble();
    world.command('p1', {'type': 'input', 'moveX': double.infinity});
    world.command('p1', {'type': 'input', 'moveZ': 'fast'});
    world.update(0.05);
    var p = world.snapshot()['players']['p1'] as Map<String, dynamic>;
    expect((p['x'] as num).toDouble(), sx); // never moved
    expect((p['z'] as num).toDouble(), sz);

    world.command('p1', {'type': 'input', 'moveZ': -0.5});
    world.update(0.05);
    p = world.snapshot()['players']['p1'] as Map<String, dynamic>;
    expect((p['z'] as num).toDouble(), lessThan(sz));
  });

  test('two players are independent and both replicate', () {
    final world = KinematicWorldAuthority();
    world.addPlayer('p1', 'A', null);
    world.addPlayer('p2', 'B', null);
    // A walks east, B stays.
    world.command('p1', {'type': 'input', 'moveX': 1});
    for (var i = 0; i < 100; i++) {
      world.update(0.05);
    }
    final players = world.snapshot()['players'] as Map<String, dynamic>;
    final a = players['p1'] as Map<String, dynamic>;
    final b = players['p2'] as Map<String, dynamic>;
    expect((a['x'] as num).toDouble(), greaterThan(1));
    expect((b['x'] as num).toDouble(), closeTo(0, 1e-9));
    // A faces east: atan2(1, 0) = pi/2.
    expect((a['yaw'] as num).toDouble(), closeTo(math.pi / 2, 1e-6));
    // Spawns were staggered, so B is not at the origin either.
    expect((b['z'] as num).toDouble(), isNot(0));
  });

  test('disconnect stops the avatar; removal drops it from snapshots', () {
    final world = KinematicWorldAuthority();
    world.addPlayer('p1', 'A', null);
    world.command('p1', {'type': 'input', 'moveX': 1});
    for (var i = 0; i < 40; i++) {
      world.update(0.05);
    }
    final moving = (world.snapshot()['players']['p1'] as Map)['x'] as num;

    world.disconnect('p1'); // inputs cleared
    final xAtStop = moving.toDouble();
    for (var i = 0; i < 40; i++) {
      world.update(0.05);
    }
    final after = (world.snapshot()['players']['p1'] as Map)['x'] as num;
    // Deceleration is bounded by `acceleration`: the stop distance is at
    // most v^2/(2a) plus one tick of overshoot — and after 2 s the avatar
    // has fully stopped (no further movement).
    final drift = after.toDouble() - xAtStop;
    expect(drift, lessThan(4.5 * 4.5 / 60 + 4.5 * 0.05 + 1e-9));
    world.update(0.05);
    final settled =
        (world.snapshot()['players']['p1'] as Map)['x'] as num;
    expect(settled.toDouble(), closeTo(after.toDouble(), 1e-9));

    world.removePlayer('p1');
    expect(
      (world.snapshot()['players'] as Map<String, dynamic>).containsKey('p1'),
      isFalse,
    );
  });

  test('welcome carries the assigned spawn point', () {
    final world = KinematicWorldAuthority();
    world.addPlayer('p1', 'A', null);
    final welcome = world.welcome('p1');
    final spawn = welcome['spawn'] as Map<String, dynamic>;
    expect(spawn.containsKey('x'), isTrue);
    expect(spawn.containsKey('z'), isTrue);
  });
}

double _travel(KinematicWorldAuthority world, {required bool run}) {
  world.addPlayer('p1', 'A', null);
  final spawn = world.welcome('p1')['spawn'] as Map<String, dynamic>;
  final startX = (spawn['x'] as num).toDouble();
  world.command('p1', {'type': 'input', 'moveX': 1, 'run': run});
  for (var i = 0; i < 40; i++) {
    world.update(0.05); // 2 simulated seconds
  }
  final p = world.snapshot()['players']['p1'] as Map<String, dynamic>;
  return (p['x'] as num).toDouble() - startX; // displacement, not position
}

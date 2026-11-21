import 'package:client/src/playback_clock.dart';
import 'package:test/test.dart';

void main() {
  test('jittery 20Hz arrivals cannot stop or reverse 60Hz playback', () {
    final clock = PlaybackClock()..observe(time: 0, receivedAt: 0);
    var previous = clock.sample(0), nextPacket = 1;
    const jitter = [.018, -.012, .008, -.009, .022, -.015];
    for (var frame = 1; frame <= 600; frame++) {
      final now = frame / 60;
      while (nextPacket * .05 + jitter[nextPacket % jitter.length] <= now) {
        final time = nextPacket * .05;
        clock.observe(
          time: time,
          receivedAt: time + jitter[nextPacket % jitter.length],
        );
        nextPacket++;
      }
      final current = clock.sample(now);
      expect(
        current - previous,
          inInclusiveRange(.99 / 60 - 1e-10, 1.01 / 60 + 1e-10),
      );
      previous = current;
    }
  });

  test('lost packets keep playback advancing on the same clock', () {
    final clock = PlaybackClock()..observe(time: 5, receivedAt: 10);
    expect(clock.sample(10.5), closeTo(5.5, 1e-9));
    clock.observe(time: 5.5, receivedAt: 10.51);
    expect(clock.sample(10.52), closeTo(5.5198, 1e-9));
  });

  test('resuming a paused authority reanchors its stopped simulation time', () {
    final clock = PlaybackClock()..observe(time: 5, receivedAt: 10);
    clock.sample(12);
    clock.observe(time: 5.05, receivedAt: 12.05);
    expect(clock.sample(12.05), closeTo(5.05, 1e-9));
    expect(clock.sample(12.1), closeTo(5.1, 1e-9));
  });

  test('epoch and reconnect reset discards the preceding clock', () {
    final clock = PlaybackClock()..observe(time: 100, receivedAt: 10);
    clock.sample(11);
    clock.reset();
    clock.observe(time: 0, receivedAt: 12);
    expect(clock.sample(12.1), closeTo(.1, 1e-9));
  });

  test('clock drift is corrected at a bounded rate', () {
    final clock = PlaybackClock()..observe(time: 0, receivedAt: 0);
    clock.sample(1);
    clock.observe(time: 1.02, receivedAt: 1);
    expect(clock.sample(1.1), closeTo(1.101, 1e-9));
    expect(clock.sample(3.1), closeTo(3.12, 1e-9));
  });

  test('an older display timestamp cannot rewind or double-count time', () {
    final clock = PlaybackClock()..observe(time: 0, receivedAt: 0);
    expect(clock.sample(1), 1);
    expect(clock.sample(.99), 1);
    expect(clock.sample(1.01), closeTo(1.01, 1e-9));
  });
}

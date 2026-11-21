/// Advances presentation continuously rather than following packet jitter.
/// All arguments and results are seconds on monotonic clocks.
class PlaybackClock {
  static const maxRateCorrection = .01;
  double? _time, _sampledAt, _arrival, _snapshotTime;

  void reset() {
    _time = _sampledAt = _arrival = _snapshotTime = null;
  }

  void observe({required double time, required double receivedAt}) {
    final arrival = _arrival, snapshotTime = _snapshotTime;
    // Local authorities can pause while menus are open. A server-time gap
    // shorter than the arrival gap identifies that discontinuity. Ordinary
    // packet loss advances both clocks and must not reset playback.
    if (arrival != null &&
        snapshotTime != null &&
        (receivedAt - arrival) - (time - snapshotTime) > .25) {
      reset();
    }
    _arrival = receivedAt;
    _snapshotTime = time;
    if (_time == null) {
      _time = time;
      _sampledAt = receivedAt;
    }
  }

  double sample(double now) {
    final time = _time, sampledAt = _sampledAt;
    if (time == null || sampledAt == null) {
      throw StateError('Observe a snapshot before sampling playback');
    }
    final elapsed = (now - sampledAt).clamp(0.0, double.infinity);
    final predicted = time + elapsed;
    final target = _snapshotTime! + now - _arrival!;
    final correction = (target - predicted).clamp(
      -elapsed * maxRateCorrection,
      elapsed * maxRateCorrection,
    );
    // A display timestamp can precede a preceding non-display sample.
    _sampledAt = now < sampledAt ? sampledAt : now;
    return _time = predicted + correction;
  }
}

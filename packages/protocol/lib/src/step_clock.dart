/// Simulation advances independently of asynchronous scene uploads. Rendering
/// interpolates the last two ticks instead of exposing variable movement steps.
class FixedStepClock {
  FixedStepClock({this.step = 1 / 120});
  final double step;
  double _remainder = 0;
  int ticks = 0;
  double get alpha => (_remainder / step).clamp(0.0, 1.0);
  double get elapsed => ticks * step;

  void discardLag() => _remainder = 0;

  void reset() {
    _remainder = 0;
    ticks = 0;
  }

  void advance(double seconds, void Function(double) simulate) {
    if (!seconds.isFinite || seconds <= 0) return;
    // Bound catch-up after a suspended window; never accumulate render backlog.
    _remainder += seconds.clamp(0.0, 0.1);
    while (_remainder + 1e-10 >= step) {
      simulate(step);
      ticks++;
      _remainder = (_remainder - step).clamp(0.0, double.infinity);
    }
  }
}

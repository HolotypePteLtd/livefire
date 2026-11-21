import 'dart:convert';
import 'dart:math' as math;

// Values are detached before retaining a baseline; simulation state is never
// rounded. 0.1 mm / 0.0001 radians exceeds the precision needed for rendering.
dynamic _wire(dynamic value, double scale) {
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException('Non-finite double in snapshot');
    }
    return (value * scale).round() / scale;
  }
  if (value is List) return [for (final v in value) _wire(v, scale)];
  if (value is Map) {
    if (value is Map<String, dynamic>) {
      return {for (final e in value.entries) e.key: _wire(e.value, scale)};
    }
    return <String, dynamic>{
      for (final e in value.entries) e.key as String: _wire(e.value, scale),
    };
  }
  return value;
}

bool _equal(dynamic a, dynamic b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_equal(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    return a.keys.every((k) => b.containsKey(k) && _equal(a[k], b[k]));
  }
  return a == b;
}

Map<String, dynamic> _difference(Map base, Map current) => {
  if (base.keys.any((k) => !current.containsKey(k)))
    'remove': [
      for (final k in base.keys)
        if (!current.containsKey(k)) k,
    ],
  'set': {
    for (final k in current.keys)
      if (!base.containsKey(k) || !_equal(base[k], current[k]))
        k: current[k] is Map
            ? {
                'patch': _difference(
                  base[k] is Map ? base[k] as Map : const {},
                  current[k] as Map,
                ),
              }
            : current[k],
  },
};

Map<String, dynamic> _apply(Map base, Map patch) {
  final result = Map<String, dynamic>.from(base);
  for (final key in patch['remove'] as List? ?? const []) {
    result.remove(key);
  }
  for (final e in (patch['set'] as Map).entries) {
    final value = e.value;
    result[e.key as String] = value is Map && value['patch'] is Map
        ? _apply(
            base[e.key] is Map ? base[e.key] as Map : const {},
            value['patch'] as Map,
          )
        : value;
  }
  return result;
}

/// Every disposable delta refers to a reliable full baseline, never to another
/// delta. Missing/reordered states cannot corrupt the following state. Baselines
/// refresh once per second and on a hole change, and are encoded once per room.
class SnapshotEncoder {
  SnapshotEncoder({this.baselineIntervalTicks = 120, int decimalPlaces = 4})
    : _scale = math.pow(10, decimalPlaces).toDouble() {
    if (baselineIntervalTicks < 1 || decimalPlaces < 0 || decimalPlaces > 12) {
      throw ArgumentError('Invalid snapshot precision or interval');
    }
  }
  final int baselineIntervalTicks;
  final double _scale;
  Map<String, dynamic>? _base;

  /// The current baseline map (quantized). Exposed so injected binary codecs
  /// can diff against exactly the baseline receivers hold.
  Map<String, dynamic>? get baseMap => _base;
  int get baselineTick => _base?['tick'] as int? ?? -1;
  String? _baselineJson;

  /// JSON is only materialized for legacy peers and reliable join/recovery.
  String? get baseline =>
      _base == null ? null : (_baselineJson ??= jsonEncode(_base));

  /// Quantizes a snapshot exactly as [encode] does before diffing, so
  /// injected binary codecs compare like-for-like values.
  Map<String, dynamic> quantize(Map<String, dynamic> snapshot) =>
      _wire(snapshot, _scale) as Map<String, dynamic>;

  Map<String, dynamic> prepare(Map<String, dynamic> snapshot) {
    final current = quantize(snapshot);
    if (_base == null ||
        current['epoch'] != _base!['epoch'] ||
        (current['tick'] as int) - baselineTick >= baselineIntervalTicks) {
      _base = current;
      _baselineJson = null;
    }
    return current;
  }

  bool isBaseline(Map<String, dynamic> current) => identical(current, _base);

  String encode(Map<String, dynamic> snapshot) =>
      encodePrepared(prepare(snapshot));

  /// Encodes a snapshot already detached by [prepare], without quantizing twice.
  String encodePrepared(Map<String, dynamic> current) {
    if (isBaseline(current)) return baseline!;
    return jsonEncode({
      'type': 'state',
      'base': baselineTick,
      'tick': current['tick'],
      'epoch': current['epoch'],
      'delta': _difference(_base!, current),
    });
  }
}

class SnapshotDecoder {
  Map<String, dynamic>? _base;
  void reset() => _base = null;

  /// Current decoded baseline (exposed for binary codecs that need the
  /// receiver's baseline map when applying their own delta frames).
  Map<String, dynamic>? get baseline => _base;

  /// Installs [frame] as the new baseline (binary full-state frames).
  void adoptBaseline(Map<String, dynamic> frame) => _base = frame;

  Map<String, dynamic>? decode(Map<String, dynamic> packet) {
    if (packet['type'] == 'snapshot' || packet['type'] == 'baseline') {
      if (packet['initial'] != true) _base = {...packet, 'type': 'snapshot'};
      return packet;
    }
    if (packet['type'] != 'state' ||
        packet['base'] != _base?['tick'] ||
        packet['epoch'] != _base?['epoch']) {
      return null;
    }
    return _apply(_base!, packet['delta'] as Map);
  }
}

/// Game-agnostic wire codec injection. The room stack historically encoded
/// snapshots as JSON text; protocol v3 lets the application supply a binary
/// codec (e.g. FlatBuffers) for the disposable state lane. Control traffic
/// (join/welcome/input/ack) remains JSON on the reliable lane.
class DecodedWireState {
  const DecodedWireState(this.snapshot, {required this.isBaseline});
  final Map<String, dynamic> snapshot;
  final bool isBaseline;
}

abstract interface class WireStateCodec {
  /// True when this codec can encode for [peer]. Codecs may require the
  /// transport to implement [BinaryGameConnection].
  bool supports(Object peer);

  /// Encodes [snapshot] as a full/baseline frame.
  List<int> encodeState(Map<String, dynamic> snapshot);

  /// Encodes the changed rows of [current] against [baseline].
  List<int> encodeDelta(
    Map<String, dynamic> baseline,
    Map<String, dynamic> current,
  );

  /// Decodes a received state frame, retaining its baseline/delta identity.
  /// [baseline] is the receiver's current baseline map (used by deltas).
  /// Returns null for a delta whose baseline has not arrived yet.
  DecodedWireState? decode(Object frame, Map<String, dynamic> baseline);
}

/// Sentinel frame marker: bytes arriving as JSON text. A binary frame can
/// never start with '{' (0x7B).
const int jsonFrameFirstByte = 0x7B;

/// Transport-agnostic authoritative room protocol: the room hub (fixed-step
/// simulation, join/resume handshake, acks, rate limits, baseline/delta
/// snapshots), the [RoomAuthority] game contract, snapshot and wire codecs,
/// connection capability interfaces, transports (the in-memory pair, plus
/// the BroadcastChannel listener/connect pair for same-origin JavaScript
/// contexts) and room
/// social. No `dart:io`, Flutter, renderer or game dependency — compiles for
/// browsers. Import `package:client/client.dart` for the resumable room client
/// and WebSocket adapters, or `package:server_sdk/server_sdk.dart` for the
/// native dedicated-server SDK.
library;

export 'src/chat.dart';
export 'src/social_client.dart';
export 'src/social_host.dart';

export 'src/connection.dart';
export 'src/room_authority.dart';
export 'src/room_hub.dart';
export 'src/memory_transport.dart';
export 'src/broadcast_channel.dart';
export 'src/snapshot_codec.dart';
export 'src/wire_codec.dart';

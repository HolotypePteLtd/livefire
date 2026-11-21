import 'package:client/client.dart';

class BrowserClient extends RoomClient<RoomSnapshot> {
  BrowserClient()
    : super(
        uri: Uri.parse('wss://example.invalid'),
        name: 'Browser',
        protocolVersion: 71,
      );
  @override
  RoomSnapshot decodeSnapshot(Map<String, dynamic> data) => RoomSnapshot(data);
}

void main() {
  // Ensure the browser barrel reaches the browser socket backend and contains
  // no native server, dart:io, physics or Flutter dependency.
  final client = BrowserClient();
  print(client.protocolVersion);
  if (Uri.base.queryParameters.containsKey('connect')) client.connect();
}

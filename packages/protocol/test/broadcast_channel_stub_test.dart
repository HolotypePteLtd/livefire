// On the Dart VM the BroadcastChannel library resolves to the stub: it
// must import cleanly and refuse to run (the browser implementation is
// exercised cross-platform by tool/test_broadcast_channel.sh under Node).
import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('native import resolves to the throwing stub', () {
    final listener = BroadcastChannelListener('any');
    expect(() => listener.start(), throwsUnsupportedError);
    expect(
      () => BroadcastChannelTransport.connect('any'),
      throwsUnsupportedError,
    );
  });
}

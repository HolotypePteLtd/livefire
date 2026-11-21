import 'dart:convert';
import 'dart:io';

import 'package:livefire_atproto_server/livefire_atproto_server.dart';

/// Generates the node's AT Protocol OAuth client key (a private EC P-256
/// JWK) and writes it to the given path. The node serves only the public
/// half at `/oauth/jwks.json`; this file stays secret.
///
/// Usage:
///   dart run tool/gen_client_jwks.dart /etc/rooms/oauth-client-jwks.json
Future<void> main(List<String> args) async {
  if (args.length != 1 || args[0].isEmpty) {
    stderr.writeln(
      'usage: dart run tool/gen_client_jwks.dart <output-path>',
    );
    exitCode = 2;
    return;
  }
  final keys = await NodeClientKeys.generate();
  final file = File(args[0]);
  await file.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(keys.toPrivateJwk()),
  );
  stderr.writeln(
    'wrote ${file.path} (kid ${keys.kid})\n'
    'Keep this file secret; the node only ever serves its public half at\n'
    '/oauth/jwks.json. Losing it invalidates signed client assertions —\n'
    'generate a new one and authorization servers will pick it up via the\n'
    'served JWKS.',
  );
}

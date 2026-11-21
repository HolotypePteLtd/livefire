import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:livefire_atproto_server/livefire_atproto_server.dart';

/// Operator diagnostic for the atproto sign-in discovery chain — the
/// thing to run when a player reports "could not start sign-in". It
/// exercises exactly what `AtprotoAuthProvider` does up to (but not
/// including) PAR, against the real network:
///
/// 1. handle - DID (entryway XRPC)
/// 2. DID document - PDS
/// 3. `GET PDS/.well-known/oauth-protected-resource` through the
///    node's own [DiscoveryClient] — printing whether the document was
///    used as-is (sharded topology) or the PDS-as-AS fallback answered
/// 4. `GET AS/.well-known/oauth-authorization-server` - issuer + PAR
///    endpoint
///
/// Usage:
///   `dart run tool/discovery_probe.dart <handle> [--entryway …] [--plc …]`
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.where((a) => !a.startsWith('--')).isEmpty) {
    stderr.writeln(
        'usage: dart run tool/discovery_probe.dart <handle> '
        '[--entryway https://bsky.social] [--plc https://plc.directory]');
    exit(64);
  }
  final handle = args.firstWhere((a) => !a.startsWith('--'));
  String option(String name, String fallback) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
  }
  final entryway = option('--entryway', 'https://bsky.social');
  final plc = option('--plc', 'https://plc.directory');

  final resolver = NodeAtprotoResolver(
    entrywayUrl: entryway,
    plcDirectoryUrl: plc,
  );
  try {
    stdout.writeln('1. resolving $handle via $entryway …');
    final identity = await resolver.resolve(handle);
    stdout.writeln('   did: ${identity.did}');

    stdout.writeln('2. PDS (DID document): ${identity.pds}');

    stdout.writeln('3. protected-resource hop …');
    final discovery = DiscoveryClient(http.Client());
    final document = await discovery.get(Uri.parse(
        '${identity.pds}/.well-known/oauth-protected-resource'));
    final doc = jsonDecode(document.body) as Map<String, dynamic>;
    final servers = (doc['authorization_servers'] as List).cast<String>();
    final asOrigin = servers.first;
    stdout.writeln('   authorization_servers: $servers'
        '${document.statusCode == 200 && servers.first == identity.pds && !document.body.contains('resource_documentation') ? '  (self-host fallback answered)' : ''}');

    stdout.writeln('4. AS metadata at $asOrigin …');
    final metadata = await http.get(Uri.parse(
        '$asOrigin/.well-known/oauth-authorization-server'));
    if (metadata.statusCode != 200) {
      stderr.writeln('   FAILED: AS metadata -> ${metadata.statusCode}');
      exit(1);
    }
    final meta = jsonDecode(metadata.body) as Map<String, dynamic>;
    stdout.writeln('   issuer: ${meta['issuer']}');
    stdout.writeln('   par:    ${meta['pushed_authorization_request_endpoint']}');
    stdout.writeln('   authorize: ${meta['authorization_endpoint']}');
    stdout.writeln('discovery OK — sign-in would reach PAR at ${meta['pushed_authorization_request_endpoint']}');
    exit(0);
  } catch (error) {
    stderr.writeln('FAILED: $error');
    exit(1);
  }
}

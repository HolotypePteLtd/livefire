import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

void main() {
  test(
    'forwarded addresses are parsed only for a trusted direct peer',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final trusted = request.uri.path == '/trusted';
        request.response.write(
          resolveClientIp(
            request,
            trustedProxies: trusted ? {'127.0.0.1', '192.0.2.1'} : {},
          ),
        );
        await request.response.close();
      });

      Future<String> clientIp(String forwarded, {bool trusted = true}) async {
        final response = await http.get(
          Uri.http(
            '127.0.0.1:${server.port}',
            trusted ? '/trusted' : '/direct',
          ),
          headers: {'X-Forwarded-For': forwarded},
        );
        expect(response.statusCode, 200);
        return response.body;
      }

      expect(await clientIp(' , , '), '127.0.0.1');
      expect(await clientIp('unknown, 192.0.2.1'), '127.0.0.1');
      expect(await clientIp('198.51.100.1, 192.0.2.1'), '198.51.100.1');
      expect(await clientIp('198.51.100.1', trusted: false), '127.0.0.1');
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rooms_atproto/rooms_atproto.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// A tiny fake rooms node implementing just the `/auth/*` surface the
/// [NodeAuthClient] consumes, including the polling semantics.
class FakeNodeAuth {
  final results = <String, List<Map<String, dynamic>>>{};
  HttpServer? _server;

  String get origin => 'http://127.0.0.1:${_server!.port}';

  /// Queue [n] pending responses, then [finalBody] with [status].
  void script(String flow, int pending, Map<String, dynamic> finalBody,
      [int status = 200]) {
    results[flow] = [
      for (var i = 0; i < pending; i++) <String, dynamic>{'status': 'pending'},
      finalBody..addAll({'__status': status}),
    ];
  }

  Future<void> start() async {
    final server = _server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) => unawaited(_handle(request)));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    Map<String, dynamic> body;
    int status = 200;
    if (request.uri.path == '/auth/start') {
      final handle = request.uri.queryParameters['handle'];
      if (handle == null || handle.isEmpty) {
        status = 400;
        body = {'error': {'code': 'invalid_request', 'message': 'handle'}};
      } else {
        body = {
          'authorizationUrl': '$origin/oauth/authorize?x=1',
          'flow': 'flow_$handle',
          'expiresInMs': 600000,
        };
        if (!results.containsKey('flow_$handle')) {
          script('flow_$handle', 2, {
            'status': 'ok',
            'joinToken': 'jt_test',
            'joinTokenExpiresAt': '2026-01-01T00:15:00Z',
            'did': 'did:plc:alice',
            'handle': handle,
            'roomKey': 'room1',
            'url': 'ws://x/play/room1?token=jt_test',
            'creatorToken': 'ct_test',
          });
        }
      }
    } else if (request.uri.path == '/auth/result') {
      final flow = request.uri.queryParameters['flow']!;
      final queue = results[flow];
      if (queue == null || queue.isEmpty) {
        status = 410;
        body = {
          'status': 'error',
          'error': {'code': 'not_found', 'message': 'unknown flow'},
        };
      } else {
        body = queue.removeAt(0);
        status = body.containsKey('__status') ? body.remove('__status') as int
            : (body['status'] == 'pending' ? 202 : 200);
        if (body['status'] == 'error' && status == 200) status = 410;
      }
    } else {
      status = 404;
      body = {'error': {'code': 'not_found', 'message': 'route'}};
    }
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

void main() {
  late FakeNodeAuth node;

  setUp(() async {
    node = FakeNodeAuth();
    await node.start();
  });

  tearDown(() => node.stop());

  test('start returns the authorization URL and flow id', () async {
    final client = NodeAuthClient(nodeBaseUrl: Uri.parse(node.origin));
    final flow = await client.start('alice.test', 'room1');
    expect(flow.flow, 'flow_alice.test');
    expect(flow.authorizationUrl.toString(), contains('/oauth/authorize'));
  });

  test('signIn polls until the node reports the credential', () async {
    final client = NodeAuthClient(
      nodeBaseUrl: Uri.parse(node.origin),
      pollInterval: const Duration(milliseconds: 10),
    );
    Uri? opened;
    final credential = await client.signIn(
      'alice.test',
      'room1',
      creator: true,
      openBrowser: (url) async {
        opened = url;
        return true;
      },
    );
    expect(opened.toString(), contains('/oauth/authorize'));
    expect(credential.joinToken, 'jt_test');
    expect(credential.did, 'did:plc:alice');
    expect(credential.roomKey, 'room1');
    expect(credential.creatorToken, 'ct_test');
    expect(credential.url, isA<Uri>());
  });

  test('a terminal error from the node surfaces as an exception', () async {
    final client = NodeAuthClient(
      nodeBaseUrl: Uri.parse(node.origin),
      pollInterval: const Duration(milliseconds: 10),
    );
    node.script(
      'flow_bob.test',
      0,
      {
        'status': 'error',
        'error': {'code': 'denied', 'message': 'user denied'},
      },
      410,
    );
    await expectLater(
      client.signIn(
        'bob.test',
        'room1',
        openBrowser: (_) async => true,
      ),
      throwsA(
        isA<AtprotoException>().having((e) => e.message, 'message',
            contains('user denied')),
      ),
    );
  });

  test('start failures map to exceptions', () async {
    final client = NodeAuthClient(nodeBaseUrl: Uri.parse(node.origin));
    final response = await http.get(
      Uri.parse('${node.origin}/auth/start?room=room1&format=json'),
    );
    expect(response.statusCode, 400);
    await expectLater(
      client.start('', 'room1'),
      throwsA(isA<AtprotoException>()),
    );
  });
}

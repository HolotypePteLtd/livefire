import 'dart:async';
import 'dart:io';

/// A single local OAuth redirect. Unrelated or invalid requests do not consume
/// the callback. The OAuth adapter validates state and issuer before accepting it.
final class OAuthLoopback {
  OAuthLoopback._(this._server, this._accept, this.applicationName) {
    _server.listen((request) => unawaited(_receive(request)));
  }

  static const path = '/oauth/callback';

  static Future<OAuthLoopback> open({
    required Future<bool> Function(Uri) accept,
    String applicationName = 'the application',
  }) async => OAuthLoopback._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    accept,
    applicationName,
  );

  final String applicationName;
  final HttpServer _server;
  final Future<bool> Function(Uri) _accept;
  final _callback = Completer<Uri>();
  bool _consumed = false;

  Uri get redirectUri =>
      Uri(scheme: 'http', host: '127.0.0.1', port: _server.port, path: path);

  Future<Uri> get callback => _callback.future;

  Future<void> _receive(HttpRequest request) async {
    try {
      final uri = request.uri;
      final params = uri.queryParametersAll;
      var status = HttpStatus.badRequest;
      var message = 'This is the $applicationName sign-in callback.';
      if (request.method != 'GET') {
        status = HttpStatus.methodNotAllowed;
      } else if (uri.path != path) {
        status = HttpStatus.notFound;
      } else if (!_consumed &&
          request.headers.value(HttpHeaders.hostHeader) ==
              redirectUri.authority &&
          params.values.every((values) => values.length == 1) &&
          params.containsKey('state') &&
          params.containsKey('iss') &&
          (params.containsKey('code') != params.containsKey('error')) &&
          await _accept(uri)) {
        if (!_consumed) {
          _consumed = true;
          status = HttpStatus.ok;
          message = 'Sign-in received. Return to $applicationName to continue.';
          _callback.complete(redirectUri.replace(query: uri.query));
        }
      }
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.text
        ..headers.set('Cache-Control', 'no-store')
        ..headers.set('Referrer-Policy', 'no-referrer')
        ..headers.set('Content-Security-Policy', "default-src 'none'")
        ..write(message);
      await request.response.close();
    } catch (_) {
      // A closed browser/socket must not turn into an unhandled async error.
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    _consumed = true;
    await _server.close(force: true);
  }
}

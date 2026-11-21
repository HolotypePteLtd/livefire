import 'dart:convert';
import 'dart:io';

/// Thin Dart client for the node's control plane (`/v1/*`,
/// `docs/control_plane_api.md`) — the parity of the TypeScript SDK's
/// Control plane client for Dart game backends: create rooms, mint
/// one-time join tokens, list and delete rooms, with the service key in
/// the Authorization header only.
///
/// ```dart
/// final of = ControlPlaneClient('https://play.holotype.com.sg', apiKey);
/// final room = await of.createRoom('relay', relayConfig);
/// final token = await of.mintToken(room['roomId'] as String);
/// ```
class ControlPlaneClient {
  ControlPlaneClient(this.baseUrl, this.apiKey)
      : _client = HttpClient();

  /// Node origin, e.g. `https://play.holotype.com.sg`.
  final String baseUrl;
  final String apiKey;
  final HttpClient _client;
  Uri? _bound;

  /// Ephemeral-port harnesses bind after construction; tests reassign.
  Uri get base => _bound ??= Uri.parse(baseUrl);

  set base(Uri value) => _bound = value;

  /// Creates a room (`POST /v1/rooms`): the full response map —
  /// roomId, roomKey, url, joinToken, joinTokenExpiresAt, creatorToken…
  Future<Map<String, dynamic>> createRoom(
    String template,
    Map<String, dynamic> config,
  ) async {
    final response = await _send('POST', '/v1/rooms', body: {
      'template': template,
      'config': config,
    });
    return _json(response);
  }

  /// Mints one more one-time join token for the room (`:roomId` keyed).
  /// `creator: true` also returns the room's creator token.
  Future<Map<String, dynamic>> mintToken(
    String roomId, {
    bool creator = false,
  }) async {
    return _json(await _send('POST', '/v1/rooms/$roomId/tokens',
        body: {'creator': creator}));
  }

  /// One page of rooms (`GET /v1/rooms`): `{rooms: […], nextCursor?}`.
  Future<Map<String, dynamic>> listRooms({int? limit}) async {
    final query = limit == null ? '' : '?limit=$limit';
    return _json(await _send('GET', '/v1/rooms$query'));
  }

  /// Looks one room up by id.
  Future<Map<String, dynamic>> room(String roomId) async =>
      _json(await _send('GET', '/v1/rooms/$roomId'));

  /// Drains a room (`DELETE`): peers get close 1001; idempotent.
  Future<void> deleteRoom(String roomId) async {
    await _send('DELETE', '/v1/rooms/$roomId');
  }

  void close() => _client.close();

  Future<HttpClientResponse> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final request = await _client.openUrl(method, base.resolve(path));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    if (response.statusCode >= 400) {
      final text = await utf8.decoder.bind(response).join();
      throw HttpException('$method $path -> ${response.statusCode}: $text',
          uri: base.resolve(path));
    }
    return response;
  }

  Future<Map<String, dynamic>> _json(HttpClientResponse response) async {
    final text = await utf8.decoder.bind(response).join();
    return text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
  }
}

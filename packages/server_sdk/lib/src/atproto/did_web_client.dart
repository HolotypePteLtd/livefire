import 'dart:io';

import 'package:atproto_identity/atproto_identity.dart' show IdentityException;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Fetches public HTTPS DID documents. Socket connections use validated
/// addresses, and each redirect is checked before sending a request.
final class DidWebClient {
  DidWebClient({http.Client? client})
    : _client =
          client ??
          IOClient(
            HttpClient()
              ..connectionTimeout = const Duration(seconds: 10)
              ..connectionFactory = _connectWeb
              ..findProxy = (_) => 'DIRECT',
          );

  final http.Client _client;

  static final _webHostPattern = RegExp(
    r'^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?'
    r'(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$',
  );

  static bool _isPrivateAddress(InternetAddress addr) {
    if (addr.isLoopback || addr.isLinkLocal || addr.isMulticast) return true;
    final raw = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv4 && raw.length == 4) {
      final a = raw[0], b = raw[1];
      if (a == 0 || a == 10 || a == 127 || a >= 224) return true;
      if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT 100.64.0.0/10
      if (a == 169 && b == 254) return true; // link-local / cloud metadata
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      return false;
    }
    if (addr.type == InternetAddressType.IPv6 && raw.length == 16) {
      final isV4Mapped =
          raw.sublist(0, 10).every((b) => b == 0) &&
          raw[10] == 0xff &&
          raw[11] == 0xff;
      if (isV4Mapped) {
        return _isPrivateAddress(
          InternetAddress.fromRawAddress(
            raw.sublist(12),
            type: InternetAddressType.IPv4,
          ),
        );
      }
      // IPv6 global unicast. Exclude 6to4 and Teredo transition addresses.
      return (raw[0] & 0xe0) != 0x20 ||
          (raw[0] == 0x20 && raw[1] == 0x02) ||
          (raw[0] == 0x20 && raw[1] == 0x01 && raw[2] == 0 && raw[3] == 0);
    }
    return false;
  }

  static void _checkWebUri(Uri uri) {
    final host = uri.host.toLowerCase();
    final literal = InternetAddress.tryParse(host);
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        (literal == null
            ? !_webHostPattern.hasMatch(host)
            : _isPrivateAddress(literal))) {
      throw IdentityException('Disallowed did:web destination for "$host"');
    }
  }

  static Future<ConnectionTask<Socket>> _connectWeb(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    _checkWebUri(uri);
    final literal = InternetAddress.tryParse(uri.host);
    final addresses = literal == null
        ? await InternetAddress.lookup(
            uri.host,
          ).timeout(const Duration(seconds: 10))
        : [literal];
    if (addresses.isEmpty || addresses.any(_isPrivateAddress)) {
      throw IdentityException('Disallowed did:web address for "${uri.host}"');
    }
    ConnectionTask<SecureSocket>? pending;
    var cancelled = false;

    Future<Socket> connect() async {
      SocketException? lastError;
      for (final address in addresses) {
        if (cancelled) break;
        try {
          // The address carries the DNS hostname for TLS and pins the dial
          // to the validated numeric address.
          final task = pending = await SecureSocket.startConnect(
            address,
            uri.port,
          );
          if (cancelled) task.cancel();
          final socket = await task.socket;
          if (!cancelled) return socket;
          socket.destroy();
        } on SocketException catch (error) {
          lastError = error;
        }
      }
      throw lastError ?? const SocketException('did:web connection cancelled');
    }

    return ConnectionTask.fromSocket(connect(), () {
      cancelled = true;
      pending?.cancel();
    });
  }

  Future<http.Response> get(Uri uri) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      _checkWebUri(uri);
      final request = http.Request('GET', uri)..followRedirects = false;
      final response = await _client.send(request);
      final location = response.headers['location'];
      if (location == null ||
          !const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return await http.Response.fromStream(response);
      }
      await response.stream.drain<void>();
      uri = uri.resolve(location);
    }
    throw IdentityException('Too many redirects resolving did:web');
  }

  void close() => _client.close();
}

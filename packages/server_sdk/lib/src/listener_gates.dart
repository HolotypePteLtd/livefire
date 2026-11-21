import 'dart:collection';
import 'dart:io';

/// Resolves the client IP for throttling. When [trustedProxies] is non-empty
/// and the direct socket peer is listed (or `'*'` is present), walks
/// `X-Forwarded-For` from right to left and returns the first IP not in
/// [trustedProxies]. Otherwise returns the direct peer IP.
String resolveClientIp(
  HttpRequest request, {
  Set<String> trustedProxies = const {},
}) {
  final remote = request.connectionInfo?.remoteAddress.address ?? 'unknown';
  if (trustedProxies.isEmpty) return remote;
  final trustAll = trustedProxies.contains('*');
  if (!trustAll && !trustedProxies.contains(remote)) return remote;
  final forwarded = request.headers['x-forwarded-for'] ?? const [];
  for (final field in forwarded.reversed) {
    for (final part in field.split(',').reversed) {
      final address = InternetAddress.tryParse(part.trim());
      if (address == null) continue;
      final ip = InternetAddress.fromRawAddress(address.rawAddress).address;
      if (trustAll || !trustedProxies.contains(ip)) {
        return ip;
      }
    }
  }
  return remote;
}

/// Cross-origin upgrade gate: with a non-empty allowlist, the `Origin`
/// header must be present and exactly listed (after normalization: ASCII
/// lowercase, default ports stripped). Browsers always send Origin on
/// WebSocket upgrades; native clients must set it to one of the listed
/// origins. Entries are full origins — `https://game.example.com`; an empty
/// allowlist allows every origin (local development).
class OriginGate {
  OriginGate(List<String> origins)
      : _allowed = Set.of(origins.map(_normalize));

  final Set<String> _allowed;

  /// True when the Origin check is enforced.
  bool get enforced => _allowed.isNotEmpty;

  bool allowed(String? origin) {
    if (!enforced) return true;
    return origin != null && _allowed.contains(_normalize(origin));
  }

  static String _normalize(String origin) {
    final value = origin.trim().toLowerCase();
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return value;
    final port = uri.hasPort && uri.port != _defaultPort(uri.scheme)
        ? ':${uri.port}'
        : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  static int _defaultPort(String scheme) => scheme == 'https' ? 443 : 80;
}

/// Sliding-window per-IP throttle for connection attempts on the listener.
/// Window state is pruned lazily; long-dead IPs drop out on the next pass.
class IpThrottle {
  IpThrottle({this.maxPerWindow = 30, this.window = const Duration(minutes: 1)});

  /// Allowed attempts per [window] per IP.
  final int maxPerWindow;
  final Duration window;

  final _attempts = <String, Queue<DateTime>>{};
  DateTime? _lastPrune;

  /// Records an attempt from [ip] and reports whether it fits the window.
  bool allow(String ip, [DateTime? now]) {
    final at = now ?? DateTime.now().toUtc();
    if (_attempts.length >= 1024 &&
        (_lastPrune == null || at.difference(_lastPrune!) >= window)) {
      prune(at);
      _lastPrune = at;
    }
    final stamps = _attempts.putIfAbsent(ip, Queue<DateTime>.new);
    while (stamps.isNotEmpty && stamps.first.isBefore(at.subtract(window))) {
      stamps.removeFirst();
    }
    if (stamps.length >= maxPerWindow) return false;
    stamps.addLast(at);
    return true;
  }

  /// Drops state for IPs with no attempt inside the window.
  void prune([DateTime? now]) {
    final at = now ?? DateTime.now().toUtc();
    _attempts.removeWhere((_, stamps) {
      while (stamps.isNotEmpty &&
          stamps.first.isBefore(at.subtract(window))) {
        stamps.removeFirst();
      }
      return stamps.isEmpty;
    });
  }

  /// Tracked IPs (metrics/tests).
  int get trackedIps => _attempts.length;
}

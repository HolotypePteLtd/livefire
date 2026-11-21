import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

/// Why a join token failed verification.
enum TokenProblem { badSignature, expired, wrongRoom, malformed }

/// The verified contents of a join or creator token.
class TokenPayload {
  const TokenPayload({
    required this.roomKey,
    required this.expiresAt,
    required this.creator,
    required this.nonce,
    this.did,
    this.handle,
  });

  /// The room this token opens.
  final String roomKey;

  /// Expiry (epoch milliseconds).
  final int expiresAt;

  /// Leader claim; creator tokens are additionally presented in the join
  /// payload where the authority's seam consumes them.
  final bool creator;

  /// One-time-use id; consumption is tracked by the caller's ledger.
  final String nonce;

  /// The verified AT Protocol DID of the token holder (atproto provider
  /// only; absent for guest tokens). Drives the hub's adapter-verified
  /// identity: bans, moderation and resume binding.
  final String? did;

  /// The handle the DID was resolved from at mint time (display only).
  final String? handle;
}

/// The verified contents of a panel session token (`ps_` prefix).
class PanelSession {
  const PanelSession({
    required this.did,
    required this.expiresAt,
    this.handle,
  });

  /// The signed-in admin's DID.
  final String did;

  /// Expiry (epoch milliseconds).
  final int expiresAt;

  /// The handle the DID signed in with (display only).
  final String? handle;
}

/// The outcome of [JoinTokens.verify]: either a verified payload or the
/// first rule the token failed.
class TokenCheck {
  const TokenCheck.ok(this.payload) : problem = null;
  const TokenCheck.failed(this.problem) : payload = null;

  final TokenPayload? payload;
  final TokenProblem? problem;
  bool get ok => payload != null;
}

/// The verified contents of a guest session token (`gs_` prefix) — the
/// identity-ladder counterpart of [PanelSession] for device accounts
/// (`/ident/device-account`, `/ident/recover`).
class GuestSession {
  const GuestSession({
    required this.did,
    required this.expiresAt,
    this.handle,
    this.guest = true,
  });

  /// The device account's DID.
  final String did;

  /// Expiry (epoch milliseconds).
  final int expiresAt;

  /// The guest handle (display only).
  final String? handle;

  /// Always true in v1 (future upgraded accounts may carry gs_ too).
  final bool guest;
}

/// The outcome of [JoinTokens.verifyGuestSession].
class PanelSessionCheck {
  const PanelSessionCheck.ok(this.session) : problem = null;
  const PanelSessionCheck.failed(this.problem) : session = null;

  final PanelSession? session;
  final TokenProblem? problem;
  bool get ok => session != null;
}

/// The outcome of [JoinTokens.verifyGuestSession].
class GuestSessionCheck {
  const GuestSessionCheck.ok(this.session) : problem = null;
  const GuestSessionCheck.failed(this.problem) : session = null;

  final GuestSession? session;
  final TokenProblem? problem;
  bool get ok => session != null;
}

/// Tracks one-time consumption of join tokens by nonce. The node uses the
/// SQLite store; tests use an in-memory set. **Join** tokens are one-time;
/// creator tokens are presented per join attempt and are not consumed here.
abstract interface class TokenLedger {
  /// Records [nonce] as used. Returns false if it was already used.
  bool consume(String nonce);
}

/// In-memory [TokenLedger] for tests and single-process embedders.
class MemoryTokenLedger implements TokenLedger {
  final _used = <String>{};

  @override
  bool consume(String nonce) => _used.add(nonce);
}

/// Stateless HMAC-SHA256-signed room tokens (`docs/control_plane_api.md` →
/// Token semantics), minted by the node's control plane under a node secret
/// and verified by the listener **before** any WebSocket upgrade.
///
/// Format: `jt_<base64url(payload)>.<base64url(hmac)>` where the payload is
/// `{rm, exp, cr, jti}`. Tokens expire (default 15 minutes), are bound to
/// one room key, and — for join tokens — are single-use through the
/// caller's [TokenLedger]. Creator tokens carry `cr: true` and use the
/// `ct_` prefix; the signed-claim upgrade (SEAM join-token) swaps the
/// authority's string comparison for verification of exactly this payload.
class JoinTokens {
  JoinTokens(List<int> secret, {this.defaultTtl = const Duration(minutes: 15)})
    : _key = secret;

  final List<int> _key;
  final Duration defaultTtl;

  /// Mints a one-time join token for [roomKey]. DID-bearing tokens carry
  /// the atproto identity the hub binds the peer to.
  String mintJoin(
    String roomKey, {
    DateTime? now,
    Duration? ttl,
    String? did,
    String? handle,
  }) => _mint(
    'jt_',
    roomKey,
    creator: false,
    now: now,
    ttl: ttl,
    did: did,
    handle: handle,
  );

  /// Mints the room creator's leader-claim token (`ct_` prefix).
  String mintCreator(
    String roomKey, {
    DateTime? now,
    Duration? ttl,
    String? did,
  }) => _mint(
    'ct_',
    roomKey,
    creator: true,
    now: now,
    ttl: ttl,
    did: did,
  );

  /// Mints a reusable panel session token (`ps_` prefix) for a signed-in
  /// DID — same HMAC machinery as join tokens, no room binding and no
  /// one-time ledger (the panel presents it as a bearer until it expires).
  String mintPanelSession(
    String did, {
    String? handle,
    DateTime? now,
    Duration? ttl,
  }) {
    final at = now ?? DateTime.now().toUtc();
    final payload = jsonEncode({
      'did': did,
      'hd': ?handle,
      'exp': at.add(ttl ?? _defaultPanelTtl).millisecondsSinceEpoch,
      'jti': _nonce(),
    });
    final body = base64Url.encode(utf8.encode(payload));
    return 'ps_$body.${_mac('ps_$body')}';
  }

  /// Default panel session lifetime (12 h; the panel re-signs in after).
  static const _defaultPanelTtl = Duration(hours: 12);

  /// Default guest session lifetime (30 days: a game device account
  /// should survive storage-clear-free gaps without re-proving the
  /// recovery key; recovery mints a fresh one regardless).
  static const defaultGuestTtl = Duration(days: 30);

  /// Mints a reusable guest session token (`gs_` prefix) for a device
  /// account — same HMAC machinery, no room binding, no one-time ledger
  /// (a bearer until it expires). `/ident/recover` re-mints one any
  /// time the client proves the recovery key.
  String mintGuestSession(
    String did, {
    String? handle,
    bool guest = true,
    DateTime? now,
    Duration? ttl,
  }) {
    final at = now ?? DateTime.now().toUtc();
    final payload = jsonEncode({
      'did': did,
      'hd': ?handle,
      'gst': guest,
      'exp': at.add(ttl ?? defaultGuestTtl).millisecondsSinceEpoch,
      'jti': _nonce(),
    });
    final body = base64Url.encode(utf8.encode(payload));
    return 'gs_$body.${_mac('gs_$body')}';
  }

  /// Parses and signature-checks a `gs_` guest session token.
  GuestSessionCheck verifyGuestSession(String token, {required DateTime now}) {
    if (!token.startsWith('gs_')) {
      return const GuestSessionCheck.failed(TokenProblem.malformed);
    }
    final dot = token.indexOf('.');
    if (dot <= 4 || token.indexOf('.', dot + 1) != -1) {
      return const GuestSessionCheck.failed(TokenProblem.malformed);
    }
    final body = token.substring(3, dot);
    final mac = token.substring(dot + 1);
    if (!_fixedTimeEquals(mac, _mac('gs_$body'))) {
      return const GuestSessionCheck.failed(TokenProblem.badSignature);
    }
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(utf8.decode(base64Url.decode(body)))
          as Map<String, dynamic>;
    } on FormatException {
      return const GuestSessionCheck.failed(TokenProblem.malformed);
    }
    final did = payload['did'];
    final exp = payload['exp'];
    final handle = payload['hd'];
    final guest = payload['gst'];
    if (did is! String || !did.startsWith('did:') || exp is! int) {
      return const GuestSessionCheck.failed(TokenProblem.malformed);
    }
    if (handle != null && handle is! String) {
      return const GuestSessionCheck.failed(TokenProblem.malformed);
    }
    if (guest != null && guest is! bool) {
      return const GuestSessionCheck.failed(TokenProblem.malformed);
    }
    if (now.millisecondsSinceEpoch >= exp) {
      return const GuestSessionCheck.failed(TokenProblem.expired);
    }
    return GuestSessionCheck.ok(
      GuestSession(
        did: did,
        expiresAt: exp,
        handle: handle is String ? handle : null,
        guest: guest is bool ? guest : true,
      ),
    );
  }

  /// Parses and signature-checks a `ps_` panel session token.
  PanelSessionCheck verifyPanelSession(String token, {required DateTime now}) {
    if (!token.startsWith('ps_')) {
      return const PanelSessionCheck.failed(TokenProblem.malformed);
    }
    final dot = token.indexOf('.');
    if (dot <= 3 || token.indexOf('.', dot + 1) != -1) {
      return const PanelSessionCheck.failed(TokenProblem.malformed);
    }
    final body = token.substring(3, dot);
    final mac = token.substring(dot + 1);
    if (!_fixedTimeEquals(mac, _mac('ps_$body'))) {
      return const PanelSessionCheck.failed(TokenProblem.badSignature);
    }
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(
        utf8.decode(base64Url.decode(body)),
      ) as Map<String, dynamic>;
    } on FormatException {
      return const PanelSessionCheck.failed(TokenProblem.malformed);
    }
    final did = payload['did'];
    final exp = payload['exp'];
    final handle = payload['hd'];
    if (did is! String || !did.startsWith('did:') || exp is! int) {
      return const PanelSessionCheck.failed(TokenProblem.malformed);
    }
    if (handle != null && handle is! String) {
      return const PanelSessionCheck.failed(TokenProblem.malformed);
    }
    if (now.millisecondsSinceEpoch >= exp) {
      return const PanelSessionCheck.failed(TokenProblem.expired);
    }
    return PanelSessionCheck.ok(
      PanelSession(
        did: did,
        expiresAt: exp,
        handle: handle is String ? handle : null,
      ),
    );
  }

  String _mint(
    String prefix,
    String roomKey, {
    required bool creator,
    DateTime? now,
    Duration? ttl,
    String? did,
    String? handle,
  }) {
    final at = now ?? DateTime.now().toUtc();
    final payload = jsonEncode({
      'rm': roomKey,
      'exp': at.add(ttl ?? defaultTtl).millisecondsSinceEpoch,
      'cr': creator,
      'jti': _nonce(),
      'did': ?did,
      'hd': ?handle,
    });
    final body = base64Url.encode(utf8.encode(payload));
    final mac = _mac('$prefix$body');
    return '$prefix$body.$mac';
  }

  /// Parses and signature-checks [token]; then binds it to [roomKey] and
  /// the clock. Consumption is the caller's ledger, not this call.
  TokenCheck verify(
    String token, {
    required String roomKey,
    required DateTime now,
  }) {
    if (!token.startsWith('jt_') && !token.startsWith('ct_')) {
      return const TokenCheck.failed(TokenProblem.malformed);
    }
    final dot = token.indexOf('.');
    if (dot <= 3 || token.indexOf('.', dot + 1) != -1) {
      return const TokenCheck.failed(TokenProblem.malformed);
    }
    final prefix = token.substring(0, 3);
    final body = token.substring(3, dot);
    final mac = token.substring(dot + 1);
    if (!_fixedTimeEquals(mac, _mac('$prefix$body'))) {
      return const TokenCheck.failed(TokenProblem.badSignature);
    }
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(
        utf8.decode(base64Url.decode(body)),
      ) as Map<String, dynamic>;
    } on FormatException {
      return const TokenCheck.failed(TokenProblem.malformed);
    }
    final room = payload['rm'];
    final exp = payload['exp'];
    final creator = payload['cr'];
    final nonce = payload['jti'];
    final did = payload['did'];
    final handle = payload['hd'];
    if (room is! String ||
        exp is! int ||
        creator is! bool ||
        nonce is! String ||
        nonce.isEmpty) {
      return const TokenCheck.failed(TokenProblem.malformed);
    }
    if (did != null && (did is! String || !did.startsWith('did:'))) {
      return const TokenCheck.failed(TokenProblem.malformed);
    }
    if (handle != null && handle is! String) {
      return const TokenCheck.failed(TokenProblem.malformed);
    }
    if (now.millisecondsSinceEpoch >= exp) {
      return const TokenCheck.failed(TokenProblem.expired);
    }
    if (room != roomKey) {
      return const TokenCheck.failed(TokenProblem.wrongRoom);
    }
    return TokenCheck.ok(
      TokenPayload(
        roomKey: room,
        expiresAt: exp,
        creator: creator,
        nonce: nonce,
        did: did is String ? did : null,
        handle: handle is String ? handle : null,
      ),
    );
  }

  String _mac(String data) =>
      crypto.Hmac(crypto.sha256, _key).convert(utf8.encode(data)).toString();

  static String _nonce() {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    // Nonces must be unguessable: the platform CSPRNG, not a seeded PRNG.
    final random = Random.secure();
    return String.fromCharCodes([
      for (var i = 0; i < 16; i++)
        alphabet.codeUnitAt(random.nextInt(alphabet.length)),
    ]);
  }

  /// Length-independent comparison time (both sides are same-length hex
  // digests here; the guard keeps malformed input from shortcutting).
  static bool _fixedTimeEquals(String a, String b) {
    final ab = utf8.encode(a), bb = utf8.encode(b);
    if (ab.length != bb.length) return false;
    var diff = 0;
    for (var i = 0; i < ab.length; i++) {
      diff |= ab[i] ^ bb[i];
    }
    return diff == 0;
  }
}

/// Constant-time string comparison for API keys (both non-null).
bool secureEquals(String a, String b) {
  final ab = utf8.encode(a), bb = utf8.encode(b);
  // Key lengths are public in HTTP headers; only content must not leak.
  if (ab.length != bb.length) return false;
  var diff = 0;
  for (var i = 0; i < ab.length; i++) {
    diff |= ab[i] ^ bb[i];
  }
  return diff == 0;
}

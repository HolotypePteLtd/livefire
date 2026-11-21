import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

import '../join_tokens.dart';
import '../listener_gates.dart';
import '../node_store.dart';
import '../platform_store.dart';
import '../room_supervisor.dart';

/// A guest account created on the node's PDS. [password] is the
/// generated app password for the account — the node persists it (the
/// platform store) so it can later write records into the guest's repo
/// (`createSession` as the guest); the player never sees it.
class GuestAccount {
  GuestAccount({required this.did, required this.handle, this.password = ''});
  final String did;
  final String handle;
  final String password;
}

/// Why [GuestAccountHost.createAccount] failed. [conflict] marks a
/// rejected (taken) handle — the caller retries with a fresh suffix.
class GuestAccountException implements Exception {
  const GuestAccountException(this.message, {this.conflict = false});
  final String message;
  final bool conflict;
  @override
  String toString() => message;
}

/// Creates guest accounts on the node's PDS
/// (`docs/identity.md` → guest identity ladder). The node owns the
/// reservation of the `anon-*` handle namespace; implementations only
/// create the account (repo included, per the PDS) and hand back the
/// DID it assigned.
abstract interface class GuestAccountHost {
  Future<GuestAccount> createAccount(String handle);
}

/// Talks to a real (stock reference) PDS over XRPC. Live-confirmed
/// against a reference PDS 0.4.5051: `{handle}`-only createAccount is
/// refused with `InvalidInviteCode` ("No invite code provided"), and
/// neither bearer nor basic admin credentials unlock service-level
/// creation on that endpoint. The supported admin path is exactly what
/// `pdsadmin account create` does:
///
/// 1. `POST /xrpc/com.atproto.server.createInviteCode` — basic auth
///    `admin:<serviceKey>` ([serviceKey] IS the PDS admin password),
///    body `{"useCount": 1}` → `{"code": …}`;
/// 2. `POST /xrpc/com.atproto.server.createAccount` with
///    `{handle, password, inviteCode}` (no e-mail) — the password is
///    generated here, returned with the account, and persisted by the
///    node so it can later write into the guest's repo.
class HttpGuestAccountHost implements GuestAccountHost {
  HttpGuestAccountHost({
    required this.pdsUrl,
    this.serviceKey,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// The PDS origin, e.g. `https://pds.example.com`.
  final Uri pdsUrl;

  /// The PDS **admin password** (`PDS_ADMIN_PASSWORD` on the PDS):
  /// basic auth `admin:<serviceKey>` mints the invite code. There is
  /// no service-level creation mode on a stock PDS — this is the
  /// documented admin path.
  final String? serviceKey;

  final http.Client _httpClient;
  bool _closed = false;

  @override
  Future<GuestAccount> createAccount(String handle) async {
    if (_closed) throw StateError('guest account host is closed');
    final password = _generatedPassword();

    // 1. Mint a single-use invite code as the PDS admin.
    final code = await _mintInviteCode();

    // 2. Create the account with handle + generated password + code.
    final response = await _httpClient.post(
      pdsUrl.replace(
        path: '/xrpc/com.atproto.server.createAccount',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'handle': handle,
        'password': password,
        'inviteCode': code,
      }),
    );
    if (response.statusCode == 200 || response.statusCode == 201) {
      Map<String, dynamic> body;
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } on FormatException {
        throw GuestAccountException(
            'PDS createAccount returned malformed JSON');
      }
      final did = body['did'];
      if (did is! String || !did.startsWith('did:')) {
        throw const GuestAccountException(
            'PDS createAccount returned no did');
      }
      return GuestAccount(did: did, handle: handle, password: password);
    }
    // Handle-taken answers look like 400/409/422 with "handle" in the
    // body (atproto's InvalidRequestError for HandleNotAvailable et al).
    final conflict = (response.statusCode == 409 ||
            response.statusCode == 422 ||
            (response.statusCode == 400 &&
                response.body.toLowerCase().contains('handle')))
        ? true
        : false;
    throw GuestAccountException(
      'PDS createAccount failed (${response.statusCode})',
      conflict: conflict,
    );
  }

  Future<String> _mintInviteCode() async {
    final adminPassword = serviceKey;
    if (adminPassword == null || adminPassword.isEmpty) {
      throw const GuestAccountException(
          'no PDS admin password configured (node.json ident.serviceKey '
          'is required to mint invite codes)');
    }
    final response = await _httpClient.post(
      pdsUrl.replace(
        path: '/xrpc/com.atproto.server.createInviteCode',
      ),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Basic '
            '${base64.encode(utf8.encode('admin:$adminPassword'))}',
      },
      body: jsonEncode({'useCount': 1}),
    );
    if (response.statusCode != 200) {
      throw GuestAccountException(
        'PDS createInviteCode failed (${response.statusCode})',
      );
    }
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final code = body['code'];
      if (code is String && code.isNotEmpty) return code;
    } on FormatException {
      // fall through to the error below
    }
    throw const GuestAccountException(
        'PDS createInviteCode returned no code');
  }

  /// 28 unguessable characters — comfortably over the PDS's app
  /// password minimum, never shown to the player.
  static String _generatedPassword() =>
      GuestIdentityApi.generateSecret(28);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _httpClient.close();
  }
}

/// The `/ident/*` surface: the guest identity ladder
/// (`docs/identity.md`, site docs "Identity ladder").
///
/// - `GET  /ident/nonce?did=…` — a single-use challenge nonce (short
///   TTL; one outstanding per DID, process memory: a node restart just
///   makes the client fetch another).
/// - `POST /ident/device-account` `{rotationPubJwk, handle?, room?}` —
///   creates a guest account on the PDS (`anon-<6>.<handle domain>` by
///   default), stores the recovery public key in the platform store
///   (both persistence modes), and mints a `gs_` guest session. With
///   `room`, also a DID-bearing join token + play URL — the player
///   plays immediately.
/// - `POST /ident/recover` `{did, nonce, assertion, room?}` — proves
///   DID control with an ES256 JWS over `{iss, sub, nonce, iat}`
///   signed by the client-held recovery key; on success the same
///   session surface is re-minted (plus a `ps_` panel session when the
///   DID is a panel admin).
///
/// No session is required for any of it — the recovery key IS the
/// credential. CORS-open like `/auth/*`: the flow's secrets (nonce,
/// assertion, session) are unguessable bearers, so any origin may
/// present one. Every route passes the listener's per-IP throttle.
///
/// **Trust note** (docs/identity.md): recovery keys are APP-LEVEL. The
/// PDS-level rotation key stays with the node operator, who therefore
/// outranks the client key at the PDS layer — v1 guarantees recovery
/// from session loss, not protection against a malicious operator.
class GuestIdentityApi {
  GuestIdentityApi({
    required this.platform,
    required this.tokens,
    required this.store,
    required this.supervisor,
    required this.guests,
    required this.publicBaseUrl,
    required this.throttle,
    this.handleDomain,
    this.nonceTtl = const Duration(minutes: 5),
    this.sessionTtl,
    this.clock = _systemClock,
    this.maxOutstandingNonces = 1024,
    this.trustedProxies = const {},
  });

  /// Recovery-key storage (SQLite or Supabase mode — same surface).
  final PlatformStore platform;

  /// Mints `gs_` sessions and DID-bearing join tokens.
  final JoinTokens tokens;

  /// Room persistence (validating an optional `room` early, like
  /// `/auth/start`).
  final NodeStore store;

  final RoomSupervisor supervisor;

  /// The PDS account host (see [HttpGuestAccountHost]).
  final GuestAccountHost guests;

  /// The node's public origin — `wss://…/play/<roomKey>` derives from it.
  final String publicBaseUrl;

  /// The per-IP throttle shared with the rest of the listener.
  final IpThrottle throttle;

  /// Guest handle domain; defaults to the host of [publicBaseUrl].
  final String? handleDomain;

  /// Challenge nonce lifetime.
  final Duration nonceTtl;

  /// Guest session lifetime (defaults to [JoinTokens]' 30 days).
  final Duration? sessionTtl;

  /// Injectable clock (tests).
  final DateTime Function() clock;

  /// Bound on outstanding nonces (per-DID replacement plus eviction of
  /// the oldest keeps memory flat under DID-spray).
  final int maxOutstandingNonces;

  /// Reverse-proxy peer IPs trusted to supply `X-Forwarded-For`.
  final Set<String> trustedProxies;

  final _nonces = <String, _PendingNonce>{};

  DateTime _now() => clock().toUtc();

  String get _handleDomain =>
      handleDomain ?? Uri.parse(publicBaseUrl).host;

  // ---- HTTP surface ---------------------------------------------------------

  /// Releases the guest host's HTTP client (a no-op for custom hosts).
  Future<void> close() async {
    final host = guests;
    if (host is HttpGuestAccountHost) await host.close();
  }

  Future<bool> handle(HttpRequest request) async {
    try {
      if (request.method == 'OPTIONS') {
        _cors(request);
        request.response.statusCode = 204;
        await request.response.close();
        return true;
      }
      final path = request.uri.path;
      if (path == '/ident/nonce' && request.method == 'GET') {
        await _throttled(request, _nonceRoute);
        return true;
      }
      if (path == '/ident/device-account' && request.method == 'POST') {
        await _throttled(request, _deviceAccountRoute);
        return true;
      }
      if (path == '/ident/recover' && request.method == 'POST') {
        await _throttled(request, _recoverRoute);
        return true;
      }
      return false;
    } on Exception catch (error) {
      // Operator surface: the exact failure goes to the log; the client
      // gets a generic 500 (never internals, never a hang).
      stderr.writeln('rooms-node: /ident failed: $error');
      try {
        await _error(request, 500, 'internal', 'internal error');
      } catch (_) {}
      return true;
    }
  }

  Future<void> _throttled(
    HttpRequest request,
    Future<void> Function(HttpRequest) route,
  ) async {
    final ip = resolveClientIp(request, trustedProxies: trustedProxies);
    if (!throttle.allow(ip)) {
      await _error(request, 429, 'quota_exceeded', 'too many attempts');
      return;
    }
    await route(request);
  }

  Future<void> _nonceRoute(HttpRequest request) async {
    final did = (request.uri.queryParameters['did'] ?? '').trim();
    if (did.isEmpty || !did.startsWith('did:')) {
      await _error(
          request, 400, 'invalid_request', 'did is required (did:…)');
      return;
    }
    // One outstanding nonce per DID: replace; bound the total.
    _nonces.remove(did);
    _evictExpiredNonces();
    while (_nonces.length >= maxOutstandingNonces) {
      _nonces.remove(_nonces.keys.first);
    }
    final expiresAt = _now().add(nonceTtl);
    final nonce = generateSecret(32);
    _nonces[did] = _PendingNonce(nonce: nonce, expiresAt: expiresAt);
    await _json(request, 200, {
      'nonce': nonce,
      'expiresAt': expiresAt.toIso8601String(),
      'expiresInMs': expiresAt.difference(_now()).inMilliseconds,
    });
  }

  Future<void> _deviceAccountRoute(HttpRequest request) async {
    final body = await _readJson(request);
    if (body == null) return;
    final jwk = body['rotationPubJwk'];
    if (jwk is! Map<String, dynamic>) {
      await _error(request, 400, 'invalid_request',
          'rotationPubJwk is required (an EC P-256 JWK)');
      return;
    }
    if (_validateEsJwk(jwk) case final problem?) {
      await _error(request, 400, 'invalid_request', problem);
      return;
    }
    final rawHandle = body['handle'];
    if (rawHandle != null &&
        (rawHandle is! String || !_isValidHandle(rawHandle))) {
      await _error(request, 400, 'invalid_request',
          'handle must be like name.$_handleDomain');
      return;
    }
    final room = body['room'];
    if (room != null && (room is! String || room.isEmpty)) {
      await _error(request, 400, 'invalid_request', 'room must be a string');
      return;
    }
    if (room is String) {
      final live = supervisor.room(room) != null ||
          (store.roomByKey(room)?.live ?? false);
      if (!live) {
        await _error(request, 404, 'not_found', 'unknown room');
        return;
      }
    }

    // Create the account on the PDS: auto-handle `anon-<6>.<domain>`,
    // retrying a few times if the suffix collides.
    GuestAccount account;
    try {
      account = await _createAccount(rawHandle as String?);
    } on GuestAccountException catch (error) {
      stderr.writeln(
          'rooms-node: /ident/device-account: PDS refused: $error');
      await _error(request, 502, 'account_host_unavailable',
          'could not create the guest account');
      return;
    }

    // Guest credential: the generated app password travels into the
    // platform store (both persistence modes) so the node can write
    // into the guest's repo later — the player never sees it, the
    // operator holds it (see the trust note).
    await platform.addGuestCredential(StoredGuestCredential(
      did: account.did,
      handle: account.handle,
      password: account.password,
      createdAt: _now(),
    ));

    // Recovery key: hash of the canonical public JWK + the JWK itself.
    try {
      await platform.addRecoveryKey(StoredRecoveryKey(
        did: account.did,
        pubkeyHash: RecoveryKeyMaterial.hash(jwk),
        pubkeyJwk: jwk,
        guest: true,
        createdAt: _now(),
      ));
    } on StateError {
      await _error(request, 409, 'already_registered',
          'this DID already has a recovery key');
      return;
    }

    await _finish(request, account: account, room: room as String?);
  }

  Future<void> _recoverRoute(HttpRequest request) async {
    final body = await _readJson(request);
    if (body == null) return;
    final did = body['did'];
    final nonce = body['nonce'];
    final assertion = body['assertion'];
    if (did is! String ||
        !did.startsWith('did:') ||
        nonce is! String ||
        assertion is! String) {
      await _error(request, 400, 'invalid_request',
          'did, nonce and assertion are required');
      return;
    }
    final room = body['room'];
    if (room != null && (room is! String || room.isEmpty)) {
      await _error(request, 400, 'invalid_request', 'room must be a string');
      return;
    }
    if (room is String) {
      final live = supervisor.room(room) != null ||
          (store.roomByKey(room)?.live ?? false);
      if (!live) {
        await _error(request, 404, 'not_found', 'unknown room');
        return;
      }
    }

    final stored = await platform.recoveryKeyFor(did);
    if (stored == null) {
      await _error(request, 404, 'not_found', 'unknown did');
      return;
    }

    // The nonce is consumed by THIS attempt, pass or fail — one shot
    // per challenge, exactly like a one-time password.
    final pending = _nonces.remove(did);
    final now = _now();
    if (pending == null ||
        pending.nonce != nonce ||
        now.isAfter(pending.expiresAt)) {
      await _error(
          request, 403, 'invalid_nonce', 'nonce unknown, expired or used');
      return;
    }

    final problem = _verifyRecoveryAssertion(
      assertion: assertion,
      did: did,
      nonce: nonce,
      now: now,
      jwk: stored.pubkeyJwk,
    );
    if (problem != null) {
      await _error(request, 403, 'bad_assertion', problem);
      return;
    }

    await _finish(
      request,
      account: GuestAccount(did: did, handle: _recoveryHandle(body, stored)),
      room: room as String?,
    );
  }

  /// The handle shown after recovery: the assertion's optional `hd`
  /// claim is untrusted display data, so fall back to the stored row
  /// having no handle at all — the DID is the identity.
  String _recoveryHandle(
    Map<String, dynamic> body,
    StoredRecoveryKey stored,
  ) {
    final claimed = body['handle'];
    return claimed is String && _isValidHandle(claimed) ? claimed : '';
  }

  Future<GuestAccount> _createAccount(String? requested) async {
    if (requested != null && requested.isNotEmpty) {
      return guests.createAccount(requested);
    }
    GuestAccountException? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      final handle = 'anon-${generateSecret(6)}.$_handleDomain';
      try {
        return await guests.createAccount(handle);
      } on GuestAccountException catch (error) {
        if (!error.conflict) rethrow;
        last = error;
      }
    }
    throw last ??
        const GuestAccountException('handle generation exhausted retries');
  }

  Future<void> _finish(
    HttpRequest request, {
    required GuestAccount account,
    required String? room,
  }) async {
    String? joinToken;
    DateTime? joinExpiry;
    if (room != null && room.isNotEmpty) {
      final live = supervisor.room(room) != null ||
          (store.roomByKey(room)?.live ?? false);
      if (!live) {
        await _error(request, 404, 'not_found', 'unknown room');
        return;
      }
      final mintedAt = _now();
      joinExpiry = mintedAt.add(tokens.defaultTtl);
      joinToken = tokens.mintJoin(
        room,
        now: mintedAt,
        did: account.did,
        handle: account.handle.isEmpty ? null : account.handle,
      );
    }
    final now = _now();
    final session = tokens.mintGuestSession(
      account.did,
      handle: account.handle.isEmpty ? null : account.handle,
      guest: true,
      now: now,
      ttl: sessionTtl,
    );
    // Panel access for admins via the same proof (the brief's optional
    // ps_-style session): recovery of an admin DID unlocks the panel
    // without a full Bluesky round-trip.
    final panelSession = platform.isAdmin(account.did)
        ? tokens.mintPanelSession(account.did,
            handle: account.handle.isEmpty ? null : account.handle, now: now)
        : null;
    final sessionExpiresAt =
        now.add(sessionTtl ?? JoinTokens.defaultGuestTtl);
    await _json(request, 200, {
      'status': 'ok',
      'did': account.did,
      'handle': account.handle,
      'session': session,
      'sessionExpiresAt': sessionExpiresAt.toIso8601String(),
      'panelSession': ?panelSession,
      'joinToken': ?joinToken,
      'joinTokenExpiresAt': ?joinExpiry?.toIso8601String(),
      'roomKey': ?room,
      'url': joinToken == null
          ? null
          : _playUrl(room!, joinToken).toString(),
    });
  }

  Uri _playUrl(String roomKey, String joinToken) {
    final base = Uri.parse(publicBaseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/play/$roomKey',
      queryParameters: {'token': joinToken},
    );
  }

  // ---- Nonce bookkeeping ----------------------------------------------------

  void _evictExpiredNonces() {
    final now = _now();
    _nonces.removeWhere((_, pending) => now.isAfter(pending.expiresAt));
  }

  // ---- JSON / errors / CORS -------------------------------------------------

  static const _maxBodyBytes = 64 * 1024;

  Future<Map<String, dynamic>?> _readJson(HttpRequest request) async {
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in request) {
        if (builder.length + chunk.length > _maxBodyBytes) {
          await _error(
              request, 413, 'payload_too_large', 'request body too large');
          return null;
        }
        builder.add(chunk);
      }
      if (builder.isEmpty) {
        await _error(request, 400, 'invalid_request', 'a JSON body is required');
        return null;
      }
      final text = utf8.decode(builder.takeBytes());
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        await _error(request, 400, 'invalid_request', 'body must be an object');
        return null;
      }
      return decoded;
    } on FormatException {
      await _error(request, 400, 'invalid_request', 'body is not valid JSON');
      return null;
    }
  }

  void _cors(HttpRequest request) {
    request.response.headers.set(
        HttpHeaders.accessControlAllowOriginHeader, '*');
    request.response.headers
        .set(HttpHeaders.accessControlAllowMethodsHeader, 'GET, POST');
    request.response.headers.set(
      HttpHeaders.accessControlAllowHeadersHeader,
      'Content-Type, Authorization',
    );
    request.response.headers
        .set(HttpHeaders.accessControlMaxAgeHeader, '600');
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    _cors(request);
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _error(
    HttpRequest request,
    int status,
    String code,
    String message,
  ) async {
    await _json(request, status, {
      'error': {'code': code, 'message': message},
    });
  }

  // ---- Crypto ---------------------------------------------------------------

  /// Validates an ES256 public JWK; null when usable, else the reason.
  static String? _validateEsJwk(Map<String, dynamic> jwk) {
    if (jwk['kty'] != 'EC' || jwk['crv'] != 'P-256') {
      return 'rotationPubJwk must be an EC P-256 key (kty EC, crv P-256)';
    }
    if (jwk['x'] is! String || jwk['y'] is! String) {
      return 'rotationPubJwk needs base64url x and y coordinates';
    }
    final List<int> x;
    final List<int> y;
    try {
      x = _unb64(jwk['x'] as String);
      y = _unb64(jwk['y'] as String);
    } on FormatException {
      return 'rotationPubJwk coordinates must be valid base64url';
    }
    if (x.length != 32 || y.length != 32) {
      return 'rotationPubJwk coordinates must be 32 bytes (P-256)';
    }
    final pointBytes = Uint8List(65);
    pointBytes[0] = 4;
    pointBytes.setAll(1, x);
    pointBytes.setAll(33, y);
    try {
      if (ECDomainParameters('secp256r1').curve.decodePoint(pointBytes) ==
          null) {
        return 'rotationPubJwk point is not on the P-256 curve';
      }
    } on ArgumentError {
      return 'rotationPubJwk point is not on the P-256 curve';
    }
    return null;
  }

  /// Verifies a recovery assertion: a compact ES256 JWS whose payload
  /// claims `{iss: did, sub: did, nonce, iat}`. Returns null on
  /// success, else the failure reason (never secret material).
  static String? _verifyRecoveryAssertion({
    required String assertion,
    required String did,
    required String nonce,
    required DateTime now,
    required Map<String, dynamic> jwk,
  }) {
    final parts = assertion.split('.');
    if (parts.length != 3) return 'assertion is not a JWS';
    Map<String, dynamic> decode(String part) {
      final decoded = jsonDecode(utf8.decode(_unb64(part)));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('not a JSON object');
      }
      return decoded;
    }

    final Map<String, dynamic> header;
    final Map<String, dynamic> payload;
    final List<int> signature;
    try {
      header = decode(parts[0]);
      payload = decode(parts[1]);
      signature = _unb64(parts[2]);
    } on FormatException {
      return 'assertion is not valid JWS/JSON';
    }
    if (header['alg'] != 'ES256') return 'assertion alg is not ES256';
    if (payload['iss'] != did || payload['sub'] != did) {
      return 'assertion iss/sub is not the did being recovered';
    }
    if (payload['nonce'] != nonce) return 'assertion nonce does not match';
    final iat = payload['iat'];
    final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
    if (iat is! int || (iat - nowSeconds).abs() > 300) {
      return 'assertion iat is outside the 5-minute window';
    }
    if (_validateEsJwk(jwk) case final problem?) return problem;
    if (signature.length != 64) {
      return 'assertion signature is not 64 bytes (raw r||s)';
    }
    final domain = ECDomainParameters('secp256r1');
    final pointBytes = Uint8List(65);
    pointBytes[0] = 4;
    pointBytes.setAll(1, _unb64(jwk['x'] as String));
    pointBytes.setAll(33, _unb64(jwk['y'] as String));
    final point = domain.curve.decodePoint(pointBytes);
    final verifier = Signer('SHA-256/ECDSA')
      ..init(
        false,
        PublicKeyParameter<ECPublicKey>(ECPublicKey(point!, domain)),
      );
    final ok = verifier.verifySignature(
      utf8.encode('${parts[0]}.${parts[1]}'),
      ECSignature(
        _bytesBigInt(signature.sublist(0, 32)),
        _bytesBigInt(signature.sublist(32)),
      ),
    );
    return ok ? null : 'signature does not verify';
  }

  bool _isValidHandle(String handle) =>
      RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9-]+)+$')
          .hasMatch(handle) &&
      handle.endsWith('.$_handleDomain');

  /// Unguessable lowercase alphanumerics (no 0/O/1/I/l) — shared by
  /// handle suffixes, nonces and generated guest passwords.
  static String generateSecret(int length) {
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    final random = Random.secure();
    return String.fromCharCodes([
      for (var i = 0; i < length; i++)
        alphabet.codeUnitAt(random.nextInt(alphabet.length)),
    ]);
  }

  static DateTime _systemClock() => DateTime.now().toUtc();
}

class _PendingNonce {
  _PendingNonce({required this.nonce, required this.expiresAt});
  final String nonce;
  final DateTime expiresAt;
}

/// Canonical hashing for recovery public keys, shared by both
/// persistence modes: the RFC 7638-style canonical JWK text (fixed key
/// order) → SHA-256 hex.
final class RecoveryKeyMaterial {
  RecoveryKeyMaterial._();

  /// The canonical public-JWK text (sorted keys, exactly the EC
  /// signing-input fields).
  static String canonicalJwk(Map<String, dynamic> jwk) => jsonEncode({
        'crv': jwk['crv'],
        'kty': jwk['kty'],
        'x': jwk['x'],
        'y': jwk['y'],
      });

  /// The storage form of a recovery public key.
  static String hash(Map<String, dynamic> jwk) =>
      crypto.sha256.convert(utf8.encode(canonicalJwk(jwk))).toString();
}

List<int> _unb64(String value) =>
    base64Url.decode(value.padRight((value.length + 3) & ~3, '='));

BigInt _bytesBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// The node's OAuth client key material: an ES256 (P-256) key pair in JWK
/// form. The **public** half is served at `/oauth/jwks.json` for
/// authorization servers; the private half never leaves this object and
/// signs `private_key_jwt` client assertions ([ConfidentialClient]).
///
/// The private JWK file (`{"kty":"EC","crv":"P-256","x":…,"y":…,"d":…}`) is
/// supplied by configuration — never committed. Generate one with
/// `dart run tool/gen_client_jwks.dart <path>` in `packages/node`.
final class NodeClientKeys {
  NodeClientKeys._(this._d, this.x, this.y, this.kid);

  final BigInt _d;
  final List<int> x, y;

  /// RFC 7638 JWK thumbprint of the public key — the `kid` servers use to
  /// pick the right key from the JWKS document.
  final String kid;

  /// The public JWKS document served at `/oauth/jwks.json`.
  Map<String, dynamic> publicJwks() => {
    'keys': [
      {
        'kty': 'EC',
        'crv': 'P-256',
        'use': 'sig',
        'alg': 'ES256',
        'kid': kid,
        'x': _b64(x),
        'y': _b64(y),
      },
    ],
  };

  /// Signs an ES256 JWT (`header.payload.signature`, JOSE raw r||s) for
  /// RFC 7523 `private_key_jwt` client authentication.
  String signJwt(
    Map<String, dynamic> header,
    Map<String, dynamic> payload,
  ) {
    final encodedHeader = _b64(utf8.encode(jsonEncode(header)));
    final encodedPayload = _b64(utf8.encode(jsonEncode(payload)));
    final signingInput = utf8.encode('$encodedHeader.$encodedPayload');
    final signature = _ecdsa().generateSignature(signingInput) as ECSignature;
    // JOSE raw signature: 32-byte big-endian r followed by 32-byte s.
    final raw = [
      ..._bigIntBytes(signature.r, 32),
      ..._bigIntBytes(signature.s, 32),
    ];
    return '$encodedHeader.$encodedPayload.${_b64(raw)}';
  }

  /// Builds a client assertion for [clientId] against [audience] (the
  /// authorization server issuer origin, per the atproto OAuth profile):
  /// ES256 JWT, `kid` = this key's thumbprint, `iss`/`sub` = clientId,
  /// `aud` = audience, `iat` now, `exp` now + 2 minutes, random `jti`.
  String clientAssertion({required String clientId, required String audience}) {
    final now = DateTime.now().toUtc();
    return signJwt(
      {'alg': 'ES256', 'typ': 'JWT', 'kid': kid},
      {
        'iss': clientId,
        'sub': clientId,
        'aud': audience,
        'iat': now.millisecondsSinceEpoch ~/ 1000,
        'exp': now.add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/
            1000,
        'jti': _b64(List.generate(16, (_) => Random.secure().nextInt(256))),
      },
    );
  }

  static final _domain = ECDomainParameters('secp256r1');

  Signer _ecdsa() => Signer('SHA-256/DET-ECDSA')
    ..init(
      true,
      PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(_d, _domain)),
    );

  /// Generates a fresh key pair (tests and the JWKS generator tool).
  static Future<NodeClientKeys> generate() async {
    final secureRandom = FortunaRandom();
    final seed = Uint8List(32);
    for (var i = 0; i < seed.length; i++) {
      seed[i] = Random.secure().nextInt(256);
    }
    secureRandom.seed(KeyParameter(seed));
    final generator = ECKeyGenerator()
      ..init(
        ParametersWithRandom(
          ECKeyGeneratorParameters(_domain),
          secureRandom,
        ),
      );
    final pair = generator.generateKeyPair();
    final private = pair.privateKey;
    // Uncompressed point encoding: 0x04 || x(32) || y(32).
    final uncompressed = pair.publicKey.Q!.getEncoded(false);
    return NodeClientKeys._(
      private.d!,
      uncompressed.sublist(1, 33),
      uncompressed.sublist(33, 65),
      '',
    )._withKid();
  }

  NodeClientKeys _withKid() {
    final canonical = jsonEncode({
      'crv': 'P-256',
      'kty': 'EC',
      'x': _b64(x),
      'y': _b64(y),
    });
    final thumbprint = _b64(crypto.sha256.convert(utf8.encode(canonical)).bytes);
    return NodeClientKeys._(_d, x, y, thumbprint);
  }

  /// Loads a private JWK file (`kty: EC`, `crv: P-256`, base64url `x`, `y`,
  /// `d`). Throws [FormatException] on anything else — fail fast at boot.
  static Future<NodeClientKeys> fromJwkFile(String path) async {
    final raw = await File(path).readAsString();
    return fromJwk(jsonDecode(raw) as Map<String, dynamic>);
  }

  static NodeClientKeys fromJwk(Map<String, dynamic> jwk) {
    if (jwk['kty'] != 'EC' ||
        jwk['crv'] != 'P-256' ||
        jwk['x'] is! String ||
        jwk['y'] is! String ||
        jwk['d'] is! String) {
      throw const FormatException(
        'client JWKS must be an EC P-256 key with x, y and d',
      );
    }
    final x = _unb64(jwk['x'] as String);
    final y = _unb64(jwk['y'] as String);
    final d = _unb64(jwk['d'] as String);
    if (x.length != 32 || y.length != 32 || d.isEmpty || d.length > 32) {
      throw const FormatException('malformed EC P-256 JWK coordinates');
    }
    return NodeClientKeys._(
      _bytesBigInt(d),
      x,
      y,
      '',
    )._withKid();
  }

  /// The private JWK (for the generator tool to write; never served).
  Map<String, dynamic> toPrivateJwk() => {
    'kty': 'EC',
    'crv': 'P-256',
    'x': _b64(x),
    'y': _b64(y),
    'd': _b64(_bigIntBytes(_d, 32)),
  };
}

String _b64(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<int> _unb64(String value) =>
    base64Url.decode(value.padRight((value.length + 3) & ~3, '='));

List<int> _bigIntBytes(BigInt value, int length) {
  if (value.isNegative || value.bitLength > length * 8) {
    throw ArgumentError('Value does not fit in $length bytes');
  }
  final bytes = List<int>.filled(length, 0);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    bytes[i] = v.toUnsigned(8).toInt();
    v >>= 8;
  }
  return bytes;
}

BigInt _bytesBigInt(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

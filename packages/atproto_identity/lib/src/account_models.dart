/// Public identity only. Tokens and DPoP keys remain inside the account
/// manager.
final class AccountIdentity {
  const AccountIdentity({
    required this.did,
    required this.handle,
    required this.pds,
  });
  final String did, handle;
  final Uri pds;
}

/// Inject an OS credential store (Keychain &c.); this package never
/// persists credentials itself.
abstract interface class AccountVault {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

enum AtprotoError {
  authenticationRequired,
  permissionDenied,
  cancelled,
  notFound,
  unavailable,
  invalidData,
  rateLimited,
  conflict,
  networkFailure,
}

final class AtprotoException implements Exception {
  const AtprotoException(this.code, this.message, {this.retryAfter});
  final AtprotoError code;
  final String message;
  final Duration? retryAfter;
  @override
  String toString() => 'AtprotoException(${code.name}): $message';
}

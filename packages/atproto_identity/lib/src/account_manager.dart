import 'dart:async';
import 'dart:convert';

import 'package:atproto_oauth/atproto_oauth.dart';
import 'package:http/http.dart' as http;

import 'account_models.dart';
import 'oauth_loopback.dart';

/// Desktop sign-in with an AT Protocol identity. The browser handles
/// credentials; this manager handles PKCE, PAR, DPoP and DID verification
/// (through `atproto_oauth`), keeps tokens and DPoP keys to itself, and
/// persists nothing without an injected [AccountVault].
///
/// Identity-only by design: sessions request exactly the `atproto` scope.
/// There is deliberately no repository, blob or service-auth surface here —
/// games that need those grant them elsewhere. (Extracted from the original
/// consumer's account manager; the repo/blob layer did not come along.)
final class AtprotoAccountManager {
  AtprotoAccountManager({
    required AccountVault vault,
    http.Client Function()? httpClientFactory,
    IdentityResolver? identityResolver,
    required Future<bool> Function(Uri url) openBrowser,
    this.clientName = 'AT Protocol application',
    this.signInTimeout = const Duration(minutes: 5),
    this.allowPrivateNetwork = false,
  }) : _vault = vault,
       _identityResolver = identityResolver,
       _openBrowser = openBrowser,
       _httpClientFactory = httpClientFactory ?? http.Client.new;

  /// Keep the client ID stable across ephemeral callback ports so saved
  /// refresh tokens belong to the same client after a restart. This is AT
  /// Protocol's localhost development client (a public native client).
  static String clientIdForScope(String scope) => Uri(
    scheme: 'http',
    host: 'localhost',
    path: '/',
    queryParameters: {
      'redirect_uri': 'http://127.0.0.1${OAuthLoopback.path}',
      'scope': scope,
    },
  ).toString();

  OAuthClientMetadata _metadata(Uri redirect) => OAuthClientMetadata(
    clientId: clientIdForScope('atproto'),
    applicationType: 'native',
    clientName: clientName,
    clientUri: 'http://localhost',
    grantTypes: const ['authorization_code', 'refresh_token'],
    redirectUris: [redirect.toString()],
    responseTypes: const ['code'],
    scope: 'atproto',
    tokenEndpointAuthMethod: 'none',
  );

  final String clientName;

  /// Permits loopback/private authorization servers and PDS origins.
  /// Production clients keep this false (https-only, SSRF-guarded); tests
  /// and local development run it against a local fake.
  final bool allowPrivateNetwork;
  final AccountVault _vault;
  final IdentityResolver? _identityResolver;
  final http.Client Function() _httpClientFactory;
  final Future<bool> Function(Uri url) _openBrowser;
  final Duration signInTimeout;
  final _changes = StreamController<AccountIdentity?>.broadcast();
  AccountIdentity? _current;
  Future<AccountIdentity?>? _restoring;
  Future<void> _vaultQueue = Future.value();
  _SignInAttempt? _attempt;
  int _epoch = 0;
  bool _disposed = false;
  OAuthSession? _session;

  String? get did => _current?.did;
  AccountIdentity? get current => _current;
  OAuthSession? get session => _session;
  Stream<AccountIdentity?> get changes => _changes.stream;

  void _check(int epoch) {
    if (_disposed || epoch != _epoch) throw _cancelled;
  }

  void _setAccount(AccountIdentity? account) {
    _current = account;
    if (!_disposed) _changes.add(account);
  }

  // Serializing vault mutations prevents a slow write from resurrecting
  // credentials after sign-out. Epoch checks also discard late network
  // results.
  Future<T> _withVault<T>(Future<T> Function() operation) {
    final result = _vaultQueue.then((_) => operation());
    _vaultQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _save(
    int epoch,
    OAuthSession session,
    String handle, {
    bool rollbackIfCancelled = false,
  }) => _withVault(() async {
    _check(epoch);
    final previous = rollbackIfCancelled ? await _vault.read() : null;
    _check(epoch);
    try {
      await _vault.write(
        jsonEncode({
          'version': 1,
          'handle': handle,
          'session': session.toJson(),
        }),
      );
    } catch (_) {
      throw const AtprotoException(
        AtprotoError.unavailable,
        'Could not save your sign-in securely. Please try again.',
      );
    }
    if (rollbackIfCancelled && (_disposed || epoch != _epoch)) {
      if (previous == null) {
        await _vault.delete();
      } else {
        await _vault.write(previous);
      }
    }
    _check(epoch);
    _session = session;
  });

  /// Restores the persisted session, refreshing it if it has expired.
  /// Returns null when there is nothing (left) to restore.
  Future<AccountIdentity?> restore() {
    if (_disposed) return Future.error(_cancelled);
    if (_current != null || _attempt != null) return Future.value(_current);
    return _restoring ??= _restore(
      _epoch,
    ).whenComplete(() => _restoring = null);
  }

  Future<AccountIdentity?> _restore(int epoch) async {
    final client = _LimitedClient(_httpClientFactory());
    try {
      final raw = await _withVault(_vault.read);
      _check(epoch);
      if (raw == null) return null;
      late OAuthSession session;
      late String handle;
      try {
        final saved = jsonDecode(raw) as Map<String, dynamic>;
        if (saved['version'] != 1) throw const FormatException();
        session = OAuthSession.fromJson(
          saved['session'] as Map<String, dynamic>,
        );
        handle = saved['handle'] as String;
        if (session.clientId != clientIdForScope(session.scope) ||
            !session.sub.startsWith('did:') ||
            session.tokenType.toLowerCase() != 'dpop' ||
            !session.scope.split(' ').contains('atproto') ||
            session.accessToken.isEmpty ||
            session.dpopPrivateKey.isEmpty ||
            !_acceptableOrigin(session.pds) ||
            !_acceptableOrigin(session.issuer)) {
          throw const FormatException();
        }
      } on FormatException {
        await _forget(epoch);
        return null;
      } on TypeError {
        await _forget(epoch);
        return null;
      }
      if (session.expiresAt == null ||
          !session.expiresAt!.isAfter(
            DateTime.now().add(const Duration(seconds: 30)),
          )) {
        if (session.refreshToken == null || session.refreshToken!.isEmpty) {
          await _forget(epoch);
          return null;
        }
        final oauth = OAuthClient(
          _metadata(Uri.parse('http://127.0.0.1${OAuthLoopback.path}')),
          httpClient: client,
          allowPrivateNetwork: allowPrivateNetwork,
        );
        session = await oauth.refresh(session);
        await _save(epoch, session, handle);
      }
      _check(epoch);
      _session = session;
      final account = AccountIdentity(
        did: session.sub,
        handle: handle,
        pds: Uri.parse(session.pds),
      );
      _setAccount(account);
      return account;
    } on OAuthSessionRevokedException {
      await _forget(epoch);
      return null;
    } catch (error) {
      if (_disposed || epoch != _epoch) return _current;
      if (error is AtprotoException) rethrow;
      // Leave saved credentials intact on a transient/offline failure.
      throw const AtprotoException(
        AtprotoError.unavailable,
        'Saved sign-in is unavailable. You can keep playing as a guest and '
        'retry later.',
      );
    } finally {
      client.close();
    }
  }

  /// Unlike the original consumer (which required https origins), a
  /// loopback http origin is accepted so local development and tests can
  /// run against a local PDS/authorization server. Production origins must
  /// still be https.
  static bool _acceptableOrigin(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    if (uri.isScheme('https')) return true;
    return uri.isScheme('http') &&
        (uri.host == 'localhost' ||
            uri.host == '127.0.0.1' ||
            uri.host == '::1');
  }

  Future<void> _forget(int epoch) => _withVault(() async {
    _check(epoch);
    await _vault.delete();
    _check(epoch);
    _session = null;
    _setAccount(null);
  });

  Future<AccountIdentity> signIn({String? handleHint}) =>
      _signIn(handleHint: handleHint);

  Future<AccountIdentity> _signIn({String? handleHint}) async {
    if (_disposed) throw _cancelled;
    if (_current != null) {
      throw const AtprotoException(
        AtprotoError.conflict,
        'Sign out before choosing another account.',
      );
    }
    if (_attempt != null) {
      throw const AtprotoException(
        AtprotoError.conflict,
        'A sign-in is already in progress.',
      );
    }
    final handle = handleHint?.trim() ?? '';
    if (handle.isEmpty) {
      throw const AtprotoException(
        AtprotoError.authenticationRequired,
        'Enter your full handle, such as user.bsky.social.',
      );
    }
    final epoch = ++_epoch;
    final attempt = _SignInAttempt(_LimitedClient(_httpClientFactory()));
    _attempt = attempt;
    final timer = Timer(signInTimeout, () => attempt.cancel(timedOut: true));
    OAuthLoopback? callback;
    try {
      final states = InMemoryOAuthStateStore();
      callback = await OAuthLoopback.open(
        applicationName: clientName,
        accept: (uri) async {
          final context = await states.find(uri.queryParameters['state']!);
          final issuer = uri.queryParameters['iss']!;
          return context != null &&
              context.issuer?.replaceFirst(RegExp(r'/$'), '') ==
                  issuer.replaceFirst(RegExp(r'/$'), '');
        },
      );
      _check(epoch);
      final resolver = _RecordingResolver(
        _identityResolver ?? HttpIdentityResolver(httpClient: attempt.client),
      );
      final oauth = OAuthClient(
        _metadata(callback.redirectUri),
        httpClient: attempt.client,
        identityResolver: resolver,
        stateStore: states,
        allowPrivateNetwork: allowPrivateNetwork,
      );
      final authorization = await attempt.wait(oauth.authorize(handle));
      _check(epoch);
      if (!await attempt.wait(_openBrowser(authorization))) {
        throw const AtprotoException(
          AtprotoError.unavailable,
          'Could not open your browser. Please try again.',
        );
      }
      final redirect = await attempt.wait(callback.callback);
      // callback() validates state, issuer and DID, including denial
      // responses.
      final session = await attempt.wait(oauth.callback(redirect.toString()));
      _check(epoch);
      timer.cancel();
      final identity = resolver.identity!;
      await _save(epoch, session, identity.handle, rollbackIfCancelled: true);
      final account = AccountIdentity(
        did: session.sub,
        handle: identity.handle,
        pds: Uri.parse(session.pds),
      );
      _setAccount(account);
      return account;
    } catch (error) {
      _check(epoch);
      if (error is AtprotoException) rethrow;
      if (error is OAuthException &&
          error.message.startsWith('access_denied')) {
        throw _cancelled;
      }
      // Never expose OAuth errors verbatim: server bodies can contain tokens.
      throw const AtprotoException(
        AtprotoError.networkFailure,
        'Could not sign in. Check your full handle and connection, then try '
        'again.',
      );
    } finally {
      timer.cancel();
      attempt.client.close();
      await callback?.close();
      if (identical(_attempt, attempt)) _attempt = null;
    }
  }

  Future<void> cancelSignIn() async {
    final attempt = _attempt;
    if (attempt == null) return;
    ++_epoch;
    _attempt = null;
    attempt.cancel();
    // Wait for a pending sign-in write to roll back before returning. A
    // saved session retained after an offline restore must survive
    // cancellation.
    await _vaultQueue;
  }

  Future<void> signOut() async {
    final epoch = ++_epoch;
    _attempt?.cancel();
    _attempt = null;
    try {
      await _forget(epoch);
    } catch (error) {
      if (error is AtprotoException) rethrow;
      throw const AtprotoException(
        AtprotoError.unavailable,
        'Could not remove the saved sign-in. Please try signing out again.',
      );
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await cancelSignIn();
    ++_epoch;
    await _changes.close();
  }
}

const _cancelled = AtprotoException(
  AtprotoError.cancelled,
  'Sign-in cancelled. You can keep playing as a guest.',
);

final class _SignInAttempt {
  _SignInAttempt(this.client);
  final http.Client client;
  final _cancelled = Completer<bool>();

  Future<T> wait<T>(Future<T> future) => Future.any([
    future,
    _cancelled.future.then<T>(
      (timedOut) => throw AtprotoException(
        timedOut ? AtprotoError.unavailable : AtprotoError.cancelled,
        timedOut ? 'Sign-in timed out. Please try again.' : 'Sign-in cancelled.',
      ),
    ),
  ]);

  void cancel({bool timedOut = false}) {
    if (!_cancelled.isCompleted) _cancelled.complete(timedOut);
    client.close();
  }
}

final class _RecordingResolver implements IdentityResolver {
  _RecordingResolver(this.delegate);
  final IdentityResolver delegate;
  ResolvedIdentity? identity;
  @override
  Future<ResolvedIdentity> resolve(String value) async =>
      identity = await delegate.resolve(value);
}

/// Bound discovery/token responses as well as connection and body read time.
final class _LimitedClient extends http.BaseClient {
  _LimitedClient(this.inner);
  final http.Client inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner
        .send(request)
        .timeout(const Duration(seconds: 20));
    var bytes = 0;
    final body = response.stream.timeout(const Duration(seconds: 20)).map((
      chunk,
    ) {
      bytes += chunk.length;
      if (bytes > 1024 * 1024) {
        throw const FormatException('Response too large');
      }
      return chunk;
    });
    return http.StreamedResponse(
      body,
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() => inner.close();
}

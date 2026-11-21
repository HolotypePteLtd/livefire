# rooms_atproto

AT Protocol identity for Openfire, extracted from an existing game accounts
stack. The public package omits room and repository
concern. (The directory keeps the `packages/atproto_identity` path; the pub
package name is `rooms_atproto` because `atproto_identity` names the Bluesky
package that `atproto_oauth` itself depends on.)

Pure identity, three surfaces:

- **`AtprotoAccountManager`** — desktop sign-in with an AT Protocol identity
  (Bluesky &c.): the browser handles credentials through the AT Protocol
  localhost development client; the manager handles PKCE, PAR, DPoP and DID
  verification via `atproto_oauth`, keeps tokens and DPoP keys to itself,
  and persists sessions only through an injected `AccountVault`
  (Keychain/credential-store adapters live in the consuming app). Sessions
  are DID-scoped and identity-only (`atproto` scope): no repository, blob or
  service-auth surface came along from the original — games grant those
  elsewhere.
- **`OAuthLoopback`** — the single-redirect localhost callback listener for
  the desktop flow.
- **`NodeAuthClient`** — the client half of a rooms node's atproto auth
  provider (`/auth/start` → browser → poll `/auth/result`): returns a
  normal node join token whose claim set includes the verified DID. Works
  from web and desktop alike (the completion mechanism is polling; no
  `dart:io` in this class). See `docs/identity.md` in the repository root.

## Deviations from the original stack

- Repository/blob/service-auth/storage methods did not come along (they
  belonged to the original game integration).
- Restoring a session accepts a loopback `http` PDS/issuer origin for local
  development and tests; production origins remain https-only (the original
  required https unconditionally).
- `allowPrivateNetwork` (default false) relaxes the `atproto_oauth` SSRF
  guards for tests running against a local fake authorization server.

## Testing

```sh
dart pub get && dart test
```

The suite runs against `test/fake_atproto.dart` — a real-TLS in-test
authorization server (self-signed cert generated per run; `atproto_oauth`
hardcodes https for AS metadata/PAR/token). No real PDS is ever contacted.

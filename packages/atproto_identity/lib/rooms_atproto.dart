/// AT Protocol identity for Openfire.
///
/// Extracted from an existing game accounts stack
/// and stripped of every room/repository concern: this package only knows
/// how to sign a user in with their AT Protocol identity (Bluesky et al.),
/// keep the session (tokens and DPoP keys stay inside the manager), restore
/// it across restarts through an injected vault, and drive the rooms node's
/// `/auth/*` flow for web and desktop games.
library;

export 'src/account_manager.dart';
export 'src/account_models.dart';
export 'src/node_auth.dart';
export 'src/oauth_loopback.dart';

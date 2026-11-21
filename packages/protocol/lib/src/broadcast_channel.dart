/// BroadcastChannel transport: connects room hubs and clients running as
/// separate JavaScript contexts on the same origin (iframes, workers,
/// windows) over a named [BroadcastChannel](https://developer.mozilla.org/en-US/docs/Web/API/BroadcastChannel)
/// bus. The browser API is available only in JS contexts, so this library
/// conditionally exports the web implementation; on the Dart VM it resolves
/// to a stub that throws [UnsupportedError].
///
/// The bus is a broadcast medium: every message is delivered to every other
/// subscriber of the channel name, so this transport wraps every frame in a
/// tiny envelope (`{"v":1,"from":…,"to":…,"d":<frame>}`) and each side
/// ignores envelopes not addressed to it. [BroadcastChannelListener] plays
/// listener on the server side — each connecting client gets its own
/// [BroadcastChannelTransport] — and [BroadcastChannelTransport.connect]
/// plays client. Channel names are not scoped by the browser beyond the
/// origin: namespace them per deployment/page-load (the site's world demo
/// embeds a random session id) so unrelated pages never cross-talk.
///
/// Limitations the bus imposes (by design of the browser API): no delivery
/// before both sides subscribe (the handshake retries until the listener
/// answers), no binary lane (frames are strings; JSON wire format only),
/// and no notion of a connection beyond what this envelope protocol builds.
library;

export 'broadcast_channel_stub.dart'
    if (dart.library.js_interop) 'broadcast_channel_web.dart';

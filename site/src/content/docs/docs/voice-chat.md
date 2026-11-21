---
title: Voice chat and spatial audio
description: Connect a voice service to a Livefire room and play each speaker’s voice at their avatar.
---

Alice and Bob can share a voice channel while they play. For **spatial voice**, Bob hears Alice on his left when her avatar stands to his left. As she walks away, her voice gets quieter.

Livefire’s built-in `chat` setting enables text chat. To add voice, connect a voice service to your game. Livefire supplies room membership, player IDs and, in a physics room, positions. The voice service carries microphone audio over WebRTC. Each listener’s game decides where to play it. Guests can use voice without an AT Protocol account. Audio stays out of room snapshots, the PDS and Jetstream.

## Give each player access to voice

This example uses LiveKit, which you can self-host. Run a LiveKit server, install `livekit-server-sdk` in your game backend, and install `livekit-client` in your browser app. The spatial example also uses `three`. Serve the browser app over HTTPS or use localhost for development. [Run LiveKit locally](https://docs.livekit.io/transport/self-hosting/local/).

Create a voice room name unique to each running Livefire session. Use the player ID assigned in the Livefire `welcome` frame as the voice participant’s identity. Two players can have the same display name, and two different rooms can each have a `p1`.

Your game supplies a `POST /voice/token` endpoint. It needs to know which live player is asking for voice. If your backend already ties an authenticated game session to a room and player ID, look up that membership there. Otherwise, a custom room can issue a ticket.

1. In `RoomAuthority.welcome(id)`, generate a private, random, one-use ticket. Store it with the running room, player ID and expiry. Include it in that player’s `welcome` frame, where a WebSocket client can read it.
2. When the player chooses **Join voice**, send the ticket to your endpoint. Consume it atomically and check that the player is still connected and allowed to use voice. Take the room and player ID from the stored ticket.
3. Return the credentials below. If the ticket expires or the player rejoins, issue a fresh ticket through the authenticated room connection. [Room authority interface](/spec/room-authority.md) · [Join handshake](/docs/protocol-clients/#2-join--resume-handshake).

Call this function on the backend after that check. Set `LIVEKIT_URL` to the voice server’s WebSocket URL and keep the LiveKit API key and secret on the backend. Return the result privately to that player. [LiveKit token grants](https://docs.livekit.io/frontends/reference/tokens-grants/).

```js
import { AccessToken, TrackSource } from 'livekit-server-sdk';

async function voiceCredentials({ voiceRoom, playerId }) {
  const token = new AccessToken(process.env.LIVEKIT_API_KEY, process.env.LIVEKIT_API_SECRET, {
    identity: playerId,
    ttl: '2m',
  });
  token.addGrant({
    room: voiceRoom, roomJoin: true, canSubscribe: true,
    canPublish: true, canPublishSources: [TrackSource.MICROPHONE], canPublishData: false,
  });
  return { url: process.env.LIVEKIT_URL, token: await token.toJwt() };
}
```

## Join and talk

On the browser, register the playback handlers before connecting so you hear players who are already speaking. For ordinary room-wide voice, each incoming microphone track plays through an audio element.

```js
import { Room, RoomEvent, Track } from 'livekit-client';

const voice = new Room();
const playing = new Map();

function playVoice(track, playerId) {
  const element = track.attach();
  element.dataset.playerId = playerId;
  document.body.append(element);
  return () => { track.detach(element); element.remove(); };
}

function stopVoice(track) {
  playing.get(track)?.();
  playing.delete(track);
}

voice.on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
  if (publication.source === Track.Source.Microphone) {
    playing.set(track, playVoice(track, participant.identity));
  }
});
voice.on(RoomEvent.TrackUnsubscribed, stopVoice);
voice.on(RoomEvent.Disconnected, () => {
  for (const track of playing.keys()) stopVoice(track);
});

async function joinVoice(ticket) {
  await voice.startAudio();
  const response = await fetch('/voice/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ticket }),
  });
  if (!response.ok) throw new Error('Voice access was refused');
  const { url, token } = await response.json();
  await voice.connect(url, token);
}
```

Call `joinVoice(ticket)` from a **Join voice** button. Once connected, a **Turn on mic** button calls `await voice.localParticipant.setMicrophoneEnabled(true)`. If the player declines microphone access, they can still listen. Pass `false` to mute their microphone. Call `await voice.disconnect()` when they leave. [Microphone capture](https://docs.livekit.io/transport/media/publish/) · [Track playback](https://docs.livekit.io/transport/media/subscribe/).

## Play a voice at its avatar

For a three.js game, replace `playVoice` above with the version below. Put one listener on the local camera or tracked head. Call `listener.context.resume()` in the **Join voice** click handler before its first `await`. The audio element here is muted so the player hears the spatial mix only.

```js
import * as THREE from 'three';

const listener = new THREE.AudioListener();
camera.add(listener);
const speakers = new Map();

function playVoice(track, playerId) {
  const stream = new MediaStream([track.mediaStreamTrack]);
  const element = new Audio();
  element.muted = true;
  element.autoplay = true;
  element.srcObject = stream;

  const speaker = new THREE.PositionalAudio(listener);
  speaker.setRefDistance(1.5); // In a metre-scale scene, fade beyond 1.5 m.
  speaker.gain.gain.value = 0; // Wait for this player's first pose.
  speaker.setMediaStreamSource(stream);
  speakers.set(track, { playerId, speaker });
  return () => {
    speakers.delete(track);
    speaker.removeFromParent();
    speaker.disconnect();
    speaker.gain.disconnect();
    element.srcObject = null;
  };
}

function updateVoices(avatars, mutedPlayers) {
  for (const { playerId, speaker } of speakers.values()) {
    const avatar = avatars.get(playerId);
    if (avatar && speaker.parent !== avatar) avatar.add(speaker);
    speaker.gain.gain.value = avatar && !mutedPlayers.has(playerId) ? 1 : 0;
  }
}
```

Call `updateVoices` after updating the avatars you draw. Pass a map of player IDs to their three.js objects and a set of player IDs muted by this listener. For a physics room, build that map from `players[id].pose`. A relay room can publish its own pose key. Use the same interpolated avatar position for sound and drawing so they move together. Footsteps or a radio can use the same listener with a local sound file. [Player positions](/docs/physics-rooms/#render-player-positions) · [three.js positional audio](https://threejs.org/docs/pages/PositionalAudio.html).

## Leaving, muting and private conversations

Livefire’s text mute affects the local chat UI. Wire the same control to the player’s voice track as well. For room-wide playback, mute that player’s audio element. For spatial playback, add their ID to `mutedPlayers`.

On a kick, ban or leave, have your backend call LiveKit’s `RoomServiceClient.removeParticipant(voiceRoom, playerId)` and refuse further credentials for that membership. On reconnect, check membership again before restoring voice. With self-hosted LiveKit, an existing token can be reused until it expires. Check returning participants against current membership and remove anyone whose access has ended. [Token lifecycle and revocation](https://docs.livekit.io/frontends/reference/tokens-grants/#token-revocation).

Distance changes what the listener hears. If only people inside a house may receive a conversation, enforce that rule at the voice service with a separate voice room or server-controlled subscriptions.

To try it, join from two browsers with headphones. Have Alice speak while Bob turns his camera, walks away and mutes her. Check that her voice changes direction, fades with distance and goes silent on mute. Then remove Alice from the game and confirm her voice session closes too.

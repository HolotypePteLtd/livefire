/**
 * The Openfire client facade — the small surface a game integrates with.
 *
 * ```ts
 * import { Openfire } from 'openfire-sdk';
 *
 * // backend, per match (the API key never ships to clients):
 * const of = Openfire.admin(API_KEY);
 * const room = await of.createRoom({ template: 'relay', capacity: 16 });
 * const { joinToken } = await of.mintToken(room, playerName);
 *
 * // client, per player:
 * const game = await Openfire.join({
 *   url: room.url,          // or host + roomKey
 *   joinToken,
 *   name: 'Sam',
 * });
 *
 * game.chat.send('hello!');               // chat, built in
 * game.onState((state) => render(state)); // server-decided state
 * ```
 */

import { Room } from './room.ts';
import type { RoomOptions } from './room.ts';
import { admin } from './admin.ts';
import { deviceAccount } from './identity.ts';

export const Openfire = {
  /** Joins (or resumes) a room on a node; resolves at the first state frame. */
  join(options: RoomOptions): Promise<Room> {
    return Room.join(options);
  },

  /**
   * The control plane as three lines: create rooms, mint one-time join
   * tokens, list and delete rooms over the node's `/v1` API. `host`
   * defaults to the hosted node (`https://play.holotype.com.sg`).
   */
  admin,

  /**
   * The guest identity ladder: play immediately with a device account
   * (client-held ES256 keypair, zero signup), recover the same DID on
   * a new device with the recovery key (`identity.ts`).
   */
  deviceAccount,
};

export { Room } from './room.ts';
export type {
  ChatMessage,
  RoomEvent,
  RoomMember,
  RoomOptions,
  Roster,
  SocketFactory,
} from './room.ts';
export { admin } from './admin.ts';
export type {
  AdminApi,
  AdminRoom,
  CreateRoomOptions,
  MintedToken,
  RoomListing,
} from './admin.ts';
export { SnapshotDecoder, applyDelta } from './codec.ts';
export type { GameState, StateDelta } from './codec.ts';

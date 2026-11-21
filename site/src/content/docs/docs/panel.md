---
title: Developer panel
description: Manage room API keys and administrators from your node’s dashboard.
---

Open `https://<your-domain>/panel` and sign in with an admin’s AT Protocol account. A panel session lasts 12 hours. The Rooms page lists each room’s template, status, peer count, and age. To create or close rooms, use the [HTTP API](/docs/api/).

## Enable the panel

Follow the [player sign-in setup](/docs/accounts/) to enable OAuth and mount the signing key. Add your account’s DID to `adminDids` in `node.json` and recreate the node with both Compose files.

```json
{
  "adminDids": ["did:plc:your-did-here"],
  "auth": {
    "providers": ["guest", "atproto"],
    "atproto": {
      "clientName": "your game name",
      "entrywayUrl": "https://bsky.social",
      "plcDirectoryUrl": "https://plc.directory",
      "jwksPath": "/etc/rooms/oauth-client-jwks.json"
    }
  }
}
```

If the panel says *disabled*, check that you have configured an admin. If it says *not authorized*, check the signed-in DID against the admin list.

## API keys

Create a key in the Keys page, give it a label, and copy the full `sk_` value into your game backend. The panel shows the secret once. The node stores a SHA-256 hash. The panel lists the key’s prefix, creation time, room count, and tokens minted.

Revoking a key causes subsequent API requests using it to return `401`. Existing rooms continue to run. To remove a bootstrap key, edit `apiKeys` in `node.json` and restart the node.

## Storage and permissions

| Setting | SQLite (default) | Supabase Postgres |
| --- | --- | --- |
| Administrators | Edit `adminDids` in `node.json`. | `adminDids` seeds the initial list. Manage subsequent changes in the panel by DID or handle. |
| Panel-issued keys | Can manage the rooms created by that key. | Also supports a room limit (`maxRooms`) and a template allowlist (`templates`). |
| Audit log | Unavailable. | Records key and admin changes with the time, actor, and target. |

In Postgres mode, exceeding a key’s scope returns `403 key_room_limit` or `403 key_template_not_allowed`. An admin cannot revoke their own access or remove the last active admin. See [Configure Supabase](/docs/self-hosting/#platform-data-in-supabase) for migration and connection settings.

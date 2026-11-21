# Deploy Openfire with Coolify and Traefik

The [Compose file](docker-compose.yml) runs the rooms node behind Coolify's
Traefik proxy. Configure the node's domain in Coolify and route it to port
`8787`. Traefik terminates TLS and forwards WebSocket traffic.

1. Copy [the example node config](../node.example.json) to the host at
   `/opt/openfire/node.json`. Set `publicBaseUrl` to the public HTTPS
   origin, generate a random `nodeSecret` and bootstrap API key, and set
   `allowedOrigins` for your clients.
2. If you enable AT Protocol OAuth, generate the private client key on the
   host. Run `dart run tool/gen_client_jwks.dart /opt/openfire/oauth-client-jwks.json`
   from `packages/node`. Remove the JWKS mount if OAuth is disabled.
3. The container runs as UID `10001`. Make both configuration files
   readable by that UID, with mode `400`.
4. Set the build context to the repository root and deploy the Compose
   file. Set the exposed port to `"8787"` in Coolify.

Keep the configuration and private keys on the host. The Compose file mounts
them read-only. For the developer panel, set `adminDids` to the DIDs that
should have access. With [Supabase persistence](../../supabase/README.md),
apply the SQL migrations before starting the node and set the service
credentials through your deployment's environment. Room creation with a
panel-issued key requires a successful quota check from PostgreSQL.

# macOS launcher

`launcher.sh` keeps OpenCode and Hermes as separate backends and separate
Cloudflare Quick Tunnels. Quick Tunnel hostnames change after a restart; edit
the existing saved server in the iOS app so its stable ID and Keychain entry
are reused.

OpenCode listens on loopback. Hermes 0.19.1 only enables dashboard auth for a
non-loopback bind, so its launcher bind is broader; before exposing either
service, the launcher verifies that anonymous access is rejected and refuses
to create a tunnel for an already-running unauthenticated process.

## OpenCode

Create `~/opencode-mobile/server.conf`, set
`OPENCODE_SERVER_PASSWORD`, and restrict it to the current user:

```sh
chmod 600 ~/opencode-mobile/server.conf
./launcher.sh start
./launcher.sh url
```

OpenCode Quick Tunnels use REST polling because this route buffers SSE.

## Hermes

Generate a protected configuration interactively. The launcher stores only a
scrypt password hash and a random signing secret, not the login password:

```sh
./launcher.sh init-hermes
./launcher.sh start-hermes
./launcher.sh url-hermes
```

In the app, add a server with type **Hermes**, use the printed URL, the
configured username, and the original password entered during `init-hermes`.
Hermes uses password login, an in-memory HttpOnly cookie, a fresh single-use
WebSocket ticket, and `/api/ws` JSON-RPC.

The hostname is public and random; randomness is not authentication. Use a
unique strong password and stop the tunnel when remote access is not needed.
Hermes documents OAuth/OIDC or a VPN as the preferred public deployment; the
basic-password mode here is a practical zero-account option with that tradeoff.

If the VPS/proxy blocks the WebSocket upgrade, the app keeps authenticated
REST access to session lists and history but disables new prompts. It never
replays an in-flight task through another protocol because that could execute
tools twice. Hermes' polling Runs API is a separate service/port/key and is not
silently substituted by this launcher.

Hermes 0.19.1 also sends dangerous-command `approval.request` events without
a request ID and resolves replies by session FIFO. The app therefore queues
events in arrival order, exposes only the head, and clears the queue on
completion/error. The protocol still cannot bind a displayed command to a
reply after a silent server-side timeout. Review the command and answer current
prompts promptly; a complete fix requires Hermes to add request IDs (or
validate a command digest) on `approval.respond`.

Useful commands:

```sh
./launcher.sh status-hermes
./launcher.sh stop-hermes
```

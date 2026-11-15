# MCP Gateway (Elixir)

A reverse proxy and multiplexer for the Model Context Protocol. It exposes one
Streamable HTTP endpoint to MCP clients (Claude Desktop, Cursor, and others)
and aggregates tools from multiple upstream stdio MCP servers.

```mermaid
flowchart LR
    client[MCP client] -- "POST /mcp ▻ JSON-RPC / ◅ JSON or SSE" --> gateway[Elixir gateway]
    gateway -- "stdio lines ▻ / ◅ JSON-RPC" --> fs[filesystem server ▸ npx]
    gateway -- "stdio lines ▻ / ◅ JSON-RPC" --> mem[memory server ▸ npx]
    gateway -- "stdio lines ▻ / ◅ JSON-RPC" --> ...[other upstreams ...]
```

The gateway performs the MCP handshake with every upstream at boot, caches
each server's tool list, and namespaces the names as `<server>__<tool>`.
Requests that arrive during a cold start (for example, `npx -y ...` downloads)
are queued, not dropped.

## Requirements

- Elixir 1.16 or newer (OTP 26+).
- Node.js, if you use `npx`-based upstreams.

## Build and run

```bash
mix deps.get
mix test
mix run --no-halt
```

## Simple example

`examples/simple_example.sh` compiles every environment, builds the release,
boots it with one stdio upstream, and asserts the whole path: handshake,
session, `tools/list`, `tools/call`, SSE framing, notifications, and session
termination. Every step must pass, or the script exits non-zero.

```bash
bash examples/simple_example.sh
```

`examples/skills_example.sh` does the same for the skills extension
(SEP-2640): it starts its own gateway with the skills-enabled upstream and
asserts advertisement, aggregation, namespacing, `-32602` on unknown URIs,
and digest integrity of read bytes.

```bash
bash examples/skills_example.sh
```

## Docker

The image bundles the BEAM runtime plus Node.js, so `npx`-based MCP upstreams
work with nothing else installed. The gateway listens on `8080` inside the
container; publish it as `4000` to match the examples and OpenCode configs.

The gateway can only see what you mount, and the upstream is jailed to exactly
those mount points:

| On the host | In the container | Gateway sees |
| ----------- | ---------------- | ------------ |
| `$HOME/notes` | `/data` | allowed |
| `.../mcp_gateway/demo` | `/demo` | allowed |
| anything not mounted | invisible | rejected |

So every path in a tool call is a **container path** (`/data/...`, `/demo/...`),
never a host path, never `/tmp`. And the tool prefix is the upstream `name`:
`files__read_text_file`.

Canonical run — one filesystem server serving both jails:

```bash
docker run -it --rm -p 4000:8080 \
  -v "$HOME/notes:/data" \
  -v "$HOME/workspace/mcp_gateway/demo:/demo" \
  -v "$HOME/.cache/mcp-npm:/home/app/.npm" \
  -e MCP_UPSTREAMS='[{"name":"files","command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/data","/demo"]}]' \
  mcp-gateway:latest
```

`-v .../.npm` is an npm cache; without it the first call waits out a package
download, with it restarts are instant. Then point your MCP client at
`http://localhost:4000/mcp`.

Run it straight from this repository, no clone (note the `.git` suffix — it
is required, or Docker fetches the web page instead of the repo). Add the same
`-v` and `-e` flags to get the jails above; without them the gateway starts
with no upstreams and `tools/list` returns empty:

```bash
docker run -it --rm -p 4000:8080 $(docker build -q https://github.com/mschonaker/mcp-gateway.git)
```

If the ghcr package is made public, `ghcr.io/mschonaker/mcp-gateway:latest`
works in place of the `$(docker build ...)` id.

`MCP_UPSTREAMS` is the same JSON array described above. `PORT` changes the
container listen port. Build your own image with `docker build -t mcp-gateway .`.

Configure upstreams with the `MCP_UPSTREAMS` environment variable (a JSON
array) or in `config/config.exs`:

```bash
MCP_UPSTREAMS='[
  {"name": "filesystem", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]},
  {"name": "memory", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory"]}
]' PORT=4000 mix run --no-halt
```

`name` is the namespace prefix. `command` must be an executable on `PATH`.
Paths in `args` are resolved where the gateway process runs: real host paths
under `mix run`, mount points under Docker (see Docker below). `/tmp` works
under `mix run` and means nothing to a container.

## Client configuration

Point any Streamable HTTP MCP client at the gateway:

```json
{
  "mcpServers": {
    "gateway": {
      "url": "http://localhost:4000/mcp"
    }
  }
}
```

## Endpoints

| Route        | Method   | Purpose                                        |
| ------------ | -------- | ---------------------------------------------- |
| `/mcp`       | POST     | JSON-RPC 2.0. Replies JSON, or SSE if accepted |
| `/mcp`       | DELETE   | Terminate the session (needs `Mcp-Session-Id`) |
| `/mcp`       | GET      | 405. The gateway has no server-initiated stream |
| `/health`    | GET      | Liveness probe                                 |

## Curl walkthrough

Matches the docker gateway of the Docker section above: prefix `files__`
(from the upstream `name`), paths `/data` or `/demo` (the mounted jails).

```bash
URL=http://localhost:4000/mcp

# 1. initialize and capture the session id
session=$(curl -s -D - -o /dev/null -X POST "$URL" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}' \
  | grep -i mcp-session-id | tr -d '\r' | awk '{print $2}')

# 2. list all aggregated, namespaced tools
curl -s -X POST "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H "Mcp-Session-Id: $session" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq

# 3. write and read back inside the jail
curl -s -X POST "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H "Mcp-Session-Id: $session" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"files__write_file","arguments":{"path":"/data/hello.txt","content":"hello\n"}}}' | jq

# 4. end the session
curl -s -X DELETE "$URL" -H "Mcp-Session-Id: $session" -o /dev/null -w '%{http_code}\n'
```

## Modules

| File                             | Role                                                              |
| -------------------------------- | ----------------------------------------------------------------- |
| `lib/mcp_gateway/application.ex` | Supervision tree. Starts Bandit and configured upstreams.          |
| `lib/mcp_gateway/router.ex`      | Streamable HTTP endpoint. Session handling and RPC multiplexing.   |
| `lib/mcp_gateway/upstream.ex`    | GenServer per stdio server. Handshake, tool cache, call proxying.  |
| `lib/mcp_gateway/skills.ex`      | URI namespacing for the skills extension (SEP-2640).               |
| `lib/mcp_gateway/sessions.ex`    | `Mcp-Session-Id` registry (in-memory).                             |
| `priv/fake_mcp_server.exs`       | Fake upstream used by the test suite.                              |

## Skills (SEP-2640)

Upstream servers that declare the `io.modelcontextprotocol/skills` extension
are fetched at handshake. The gateway aggregates them, rewrites each skill URI
to `skill://<server>__<name>/...` so servers cannot collide, forwards
`skills/get` and `resources/read` with the original URI, and rewrites the URIs
back on the way down. Published SHA-256 digests still verify, because content
passes through byte for byte. The gateway advertises the extension only while
some upstream actually serves skills.

Client support for the extension is still rolling out. See
[docs/sep-2640-status.md](docs/sep-2640-status.md) for the ecosystem status
as of 2026-11-15.

## Known limitations

- Upstream transport is stdio only. Remote HTTP/SSE upstreams are not proxied.
- Skill URIs are namespaced with `__`, so an upstream server name must not
  contain `__` (same constraint as tool names).
- Sessions live in one node's memory. They do not survive a restart and are
  not shared across nodes.
- No authentication, rate limiting, or per-tool ACLs. Put the gateway behind
  a reverse proxy or add a Plug if you expose it.
- Server-initiated messages (SSE GET stream, sampling, roots) are rejected
  upstream and not offered downstream.

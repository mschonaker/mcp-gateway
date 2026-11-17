# MCP Gateway (Elixir)

An enterprise-oriented local MCP gateway that exposes **MCP over Streamable HTTP only** (input and output), uses **Google OIDC** for web login, keeps all runtime state **in memory** (no database), serves **SEP-2640 skills from the filesystem**, and provides local diagnostic tools.

## What it does

- **Input (clients → gateway):** Streamable HTTP MCP endpoint at `POST /mcp` (and SSE responses when requested), protected by a bearer token issued after web login.
- **Output (gateway → upstream MCPs):** remote MCP servers over **Streamable HTTP only** (no stdio). Upstream auth modes: `none`, static `bearer`, or `oauth` tokens obtained from the web UI.
- **Identity:** Google OIDC login for the web UI. Access is restricted by an allowlist file (default: `config/allowlist.txt`, currently `mschonaker@gmail.com`).
- **No database:** sessions, MCP bearer tokens, upstream configs/tokens, and policy toggles live in memory and are lost on restart.
- **Policy:** per-upstream, per-function allow/block toggles in the web UI. Default: **allowed (on)**.
- **Local MCP tools:** `local__whoami` (diagnostic identity seen by gateway) and `local__datetime` (current UTC time in ISO 8601).
- **Upstream example tools:** upstreams discovered through the web UI are exposed as `<upstream>__<tool>` (for a configured `geolocation` upstream: `geolocation__lookup_ipv4`, `geolocation__lookup_ipv6`).
- **Skills:** SEP-2640 skills loaded from the local filesystem (`skills/` by default). Example skills included: `whoami-check` and `datetime-now`.

## Requirements

- Elixir 1.16+ / OTP 26+
- A Google OAuth 2.0 / OIDC client (Web application) for local use

## Configuration

Environment variables:

- `PORT` - HTTP port (default `4000`)
- `BASE_URL` - public/local base URL used for OAuth callbacks (default `http://localhost:4000`)
- `GOOGLE_CLIENT_ID` - Google OAuth client ID
- `GOOGLE_CLIENT_SECRET` - Google OAuth client secret
- `ALLOWLIST_PATH` - path to allowlist file (default `config/allowlist.txt`)
- `SKILLS_DIR` - path to skills directory (default `skills/`)

### Google OIDC setup (local, step by step)

The gateway uses a **Web application** OAuth client with the authorization-code flow. Do this once.

**1. Create/select a Google Cloud project**
- Open https://console.cloud.google.com/ and select or create a project (e.g. `mcp-gateway`).

**2. Configure the OAuth consent screen**
- Go to **APIs & Services → OAuth consent screen**.
- Choose **External** for a personal Gmail account (or **Internal** for a Google Workspace org).
- Fill app name, user support email, and developer contact email. Save.
- Add your email under **Test users** if the app is in **Testing** (e.g. `mschonaker@gmail.com`).

**3. Create the OAuth client ID**
- Go to **APIs & Services → Credentials → + Create Credentials → OAuth client ID**.
- Application type: **Web application**.
- **Authorized JavaScript origins:** `http://localhost:4000` (origin only: no path, no trailing `/`).
- **Authorized redirect URIs:** `http://localhost:4000/auth/google/callback` (full path, exact).
- Click **Create** and copy the **Client ID** and **Client secret**.

**4. Start the gateway with the real values**
```bash
docker run --rm -p 4000:8080 \
  -e PORT=8080 \
  -e BASE_URL=http://localhost:4000 \
  -e GOOGLE_CLIENT_ID="<your-id>.apps.googleusercontent.com" \
  -e GOOGLE_CLIENT_SECRET="<your-secret>" \
  mcp-gateway:local
```
or with `mix run`:
```bash
GOOGLE_CLIENT_ID="<your-id>.apps.googleusercontent.com" \
GOOGLE_CLIENT_SECRET="<your-secret>" \
BASE_URL=http://localhost:4000 mix run --no-halt
```

**5. Sign in**
- Open `http://localhost:4000`, click **Sign in with Google**, and use an allowlisted email (`config/allowlist.txt`, default `mschonaker@gmail.com`).
- The dashboard shows the MCP bearer token for this session.

**OIDC troubleshooting**

- **`Error 401: invalid_client`** — the client ID/secret pair is not a real registered pair. Placeholders such as `"your-google-client-id"` cause this. Use the exact values from the **Web application** client, with no extra quotes/spaces/newlines. If the secret was rotated or the client deleted, create a new client.
- **`Invalid Origin: URIs must not contain a path or end with "/"`** — a callback URL was pasted into **Authorized JavaScript origins**. Put `http://localhost:4000` there (or leave it empty) and put the full `http://localhost:4000/auth/google/callback` in **Authorized redirect URIs**.
- **`redirect_uri_mismatch`** — the redirect URI in Google and the gateway's `BASE_URL + /auth/google/callback` must match exactly (scheme, host, port, path, no trailing slash).
- **`Access blocked` / consent errors** — app in **Testing** requires the account to be a **Test user**; or complete the consent-screen setup for the project.
- **Gateway says `Email not allowed: ...`** — add that email to the allowlist file and restart the gateway (the allowlist is loaded at boot).
- **Ports:** keep the host port, `BASE_URL`, and Google redirect URI consistent. The container listens on `PORT` (`8080` in the image), while `-p 4000:8080` exposes it as `4000`.

## Run locally

```bash
mix deps.get
GOOGLE_CLIENT_ID="<your-id>.apps.googleusercontent.com" \
GOOGLE_CLIENT_SECRET="<your-secret>" \
BASE_URL=http://localhost:4000 mix run --no-halt
```

Open the web UI at `http://localhost:4000`, sign in with Google, then:

- Copy the **MCP bearer token** shown on the dashboard and configure your MCP client with:
  - URL: `http://localhost:4000/mcp`
  - Header: `Authorization: Bearer <token>`
- Add upstream MCP servers (Streamable HTTP URLs), choose auth mode (none/bearer), refresh tools, and use toggles to allow/block functions.
- For upstream OAuth: save OAuth config in the upstream card and click **Connect OAuth** (flow runs in the browser; tokens stored in memory only). Callback: `BASE_URL/auth/upstream/callback`.
- Add skills by copying skill folders (with `SKILL.md`) into `SKILLS_DIR`.

## MCP surface

- `server/discover` (revision `2026-07-28`)
- `initialize`, `ping` (revisions `2024-11-05` and `2025-03-26`)
- `tools/list`, `tools/call`
  - Local: `local__whoami`, `local__datetime`
  - Remote: `<upstream>__<tool>` (subject to policy toggles); for a configured `geolocation` upstream: `geolocation__lookup_ipv4`, `geolocation__lookup_ipv6`
- `skills/list`, `skills/get` (SEP-2640, filesystem)
- `resources/list`, `resources/read` (skill files)

## Notes

- Runtime state is in-memory only; restart clears sessions, tokens, upstreams, and toggles.
- Upstream OAuth acquisition is initiated only from the web UI, never from MCP requests.
- This is a local-first implementation intended to be hardened further for production deployments.

## Run with Docker

Complete **Google OIDC setup (local, step by step)** first, then build in `mcp_gateway/`:

```bash
docker build -t mcp-gateway:local .
```

Run locally (container listens on `8080`, mapped to host `4000`):

```bash
docker run --rm -p 4000:8080 \
  -e PORT=8080 \
  -e BASE_URL=http://localhost:4000 \
  -e GOOGLE_CLIENT_ID="<your-id>.apps.googleusercontent.com" \
  -e GOOGLE_CLIENT_SECRET="<your-secret>" \
  mcp-gateway:local
```

Open `http://localhost:4000`, sign in with Google, and copy the MCP bearer token from the dashboard for your MCP client:

- URL: `http://localhost:4000/mcp`
- Header: `Authorization: Bearer <token>`

`BASE_URL` must be the exact browser-facing URL you use and must match the OAuth redirect URIs registered in Google (`$BASE_URL/auth/google/callback`) and, if used, in upstream providers (`$BASE_URL/auth/upstream/callback`).

Override allowlist/skills by mounting files and setting paths:

```bash
docker run --rm -p 4000:8080 \
  -e PORT=8080 \
  -e BASE_URL=http://localhost:4000 \
  -e GOOGLE_CLIENT_ID="..." \
  -e GOOGLE_CLIENT_SECRET="..." \
  -e ALLOWLIST_PATH=/data/allowlist.txt \
  -e SKILLS_DIR=/data/skills \
  -v "$PWD/config/allowlist.txt:/data/allowlist.txt:ro" \
  -v "$PWD/skills:/data/skills:ro" \
  mcp-gateway:local
```

All runtime state (sessions, MCP bearer token, upstream configs/tokens, toggles) is in-memory and lost on container restart.

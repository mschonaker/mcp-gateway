# Connect the GitHub MCP upstream with OAuth

This guide connects the remote GitHub MCP server to this gateway as an
**upstream MCP server**. The gateway obtains a GitHub OAuth token in the web UI
and sends that token to `https://api.githubcopilot.com/mcp/`.

This does not replace the Google sign-in for the gateway dashboard. GitHub does
not issue ID tokens, so it cannot satisfy the current OIDC login.

Reference date: **2026-11-17**. GitHub changed the labels in its OAuth App form.
The current form uses **Redirect URIs**. Older documentation and screenshots use
**Authorization callback URL**. Both refer to the same value.

## Prerequisites

- The gateway is running and you can open it in a browser. In the Docker setup,
  the URL is `http://localhost:4000`.
- `BASE_URL` matches the browser URL exactly. The Docker command sets
  `BASE_URL=http://localhost:4000`. The container port `8080` is mapped to host
  port `4000`.
- You can sign in to the dashboard with an allowlisted Google account.

## 1. Create a GitHub OAuth App

1. Open GitHub, then click your profile picture → **Settings** →
   **Developer settings** → **OAuth Apps** → **New OAuth App**. If this is your
   first app, the button says **Register a new application**.
2. Fill the form:
   - **Application name:** `mcp-gateway` or another name you recognize.
   - **Homepage URL:** the gateway base URL. Example: `http://localhost:4000`.
   - **Application description:** optional.
   - **Redirect URIs:** the exact callback URL. Example:
     ```
     http://localhost:4000/auth/upstream/callback
     ```
     Use `BASE_URL/auth/upstream/callback`. Do not add a trailing slash.
3. Leave **Allow wildcard matching** off. The exact URL is safer.
4. Leave **Enable Device Flow** off. This flow uses a browser.
5. If the form shows **Expire user access tokens**, clear that option. This
   gateway stores a refresh token but does not use it. With expiration enabled,
   you must reconnect every eight hours.
6. Click **Register application**.
7. Copy the **Client ID**. Click **Generate a new client secret** and copy the
   secret at once. GitHub shows the secret only once.

If you cannot find **Authorization callback URL**, use the **Redirect URIs**
field instead. That is the current label in the GitHub form.

## 2. Add the upstream in the dashboard

Open the dashboard. In the card that contains **Local MCP Tools** and
**Add / Update Upstream MCP (HTTP)**, add this upstream:

| Field | Value |
|-------|-------|
| name | `github` |
| url | `https://api.githubcopilot.com/mcp/` |
| auth type | `no auth` |

The OAuth configuration supplies the access token. A static bearer token is not
needed.

## 3. Save the OAuth configuration

Open **OAuth configuration** in the new `github` upstream section. Enter these
values:

| Field | Value |
|-------|-------|
| auth URL | `https://github.com/login/oauth/authorize` |
| token URL | `https://github.com/login/oauth/access_token` |
| client id | the Client ID from step 1 |
| client secret | the secret from step 1 |
| scope | `repo read:user` |

Click **Save OAuth Config**. The secret field is blank on later visits. Leave it
blank to keep the saved secret.

Click **Connect OAuth (open provider)**. Approve the request on GitHub. GitHub
redirects the browser to the callback URL. The gateway exchanges the code with
PKCE, stores the token, sets the status to `oauth connected`, and refreshes the
tool list.

Start with `repo read:user`. Add scopes only when a tool needs them. Common
additions are `read:org` for organization data and `workflow` for Actions
workflow files.

## 4. Verify the connection

- The upstream status shows `oauth connected`.
- Tools appear as `github__<tool>`. Click **Refresh Tools** if the list is empty.
- Use the new policy toggles to allow or block each tool. Blocked tools stay in
  the list, but calls and reads are refused.
- Call a tool through the gateway MCP endpoint with your dashboard bearer token.

## Limits

- **No token refresh.** The gateway stores `refresh_token` but never uses it.
  If the access token expires, click **Connect OAuth** again. Do not enable
  expiring tokens unless you accept manual reconnection.
- **Exact callback match.** The redirect URI in the GitHub app must equal
  `BASE_URL/auth/upstream/callback`, including scheme, host, and port. Change
  `BASE_URL` when you use another host or port.
- **Manual endpoints.** The gateway does not use dynamic client registration or
  `WWW-Authenticate` discovery. If GitHub changes its endpoints, update the
  OAuth configuration.
- **In-memory state.** Upstream configs, tokens, sessions, and toggles are lost
  when the gateway or container restarts. Repeat the setup after a restart.
- **Organization rules.** An organization can block the OAuth App. An
  administrator may need to approve it before it can read organization data.
- **Secret handling.** The client secret is kept in memory and is not rendered
  in the dashboard. Do not use a secret that you cannot rotate.

## Troubleshooting

| Symptom | Action |
|---------|--------|
| GitHub reports a redirect URI mismatch | Make the **Redirect URIs** value exactly `BASE_URL/auth/upstream/callback`. Keep wildcard matching off. |
| `Invalid or expired upstream OAuth state` | Start again with **Connect OAuth**. Finish within 10 minutes. |
| `Upstream OAuth failed` | Check the token URL, client ID, and client secret. Read the gateway log for the response. |
| Status returns to `configured` after saving the config | Saving the config keeps existing OAuth auth. Click **Connect OAuth** to restore the token. |
| No tools are discovered | Check the granted scopes, then click **Refresh Tools**. |
| A tool returns an authorization error | Add the required scope in GitHub, save the config, and reconnect. |

## References

Official sources:

- [GitHub remote MCP integration guide for host authors](https://github.com/github/github-mcp-server/blob/main/docs/host-integration.md)
- [Creating an OAuth app](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app)
- [Authorizing OAuth apps](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)
- [Scopes for OAuth apps](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)
- [Setting up the GitHub MCP server](https://docs.github.com/en/copilot/how-tos/copilot-in-your-ide/customize-copilot/extend-copilot-with-tools-and-context/set-up-the-github-mcp-server)

Ecosystem source:

- The current GitHub form labels were confirmed from a dashboard screenshot on
  2026-11-17. The label is **Redirect URIs**, not **Authorization callback URL**.

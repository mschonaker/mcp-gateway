defmodule McpGateway.Router do
  use Plug.Router
  require Logger

  alias McpGateway.{Auth.Google, Config, Local, Store, UpstreamHTTP}

  @protocol_version "2025-03-26"
  @legacy_versions ["2024-11-05", "2025-03-26"]
  @modern_version "2026-07-28"
  @supported_versions [@modern_version | @legacy_versions]
  @cache %{"ttlMs" => 0, "cacheScope" => "private"}
  @server_info %{"name" => "mcp-gateway", "version" => "0.2.0"}

  plug Plug.Logger
  plug :fetch_query_params
  plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason, pass: ["*/*"]
  plug :fetch_cookies
  plug :match
  plug :dispatch

  # --- Web UI ---
  get "/" do
    case current_user(conn) do
      nil -> redirect(conn, "/login")
      user -> html(conn, 200, dashboard_html(user))
    end
  end

  get "/login" do
    if Config.google_client_id() && Config.google_client_secret() do
      html(conn, 200, login_html(nil))
    else
      html(conn, 500, login_html("Google OIDC is not configured. Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET."))
    end
  end

  post "/auth/google" do
    state = random_token()
    Store.put_oauth_state(state, %{inserted_at: System.system_time(:second)})
    redirect(conn, Google.authorize_url(state))
  end

  get "/auth/google/callback" do
    code = conn.params["code"]
    state = conn.params["state"]
    saved = state && Store.pop_oauth_state(state)

    cond do
      is_nil(saved) ->
        html(conn, 400, login_html("Invalid or expired login state."))

      true ->
        case Google.exchange_code(code) do
          {:ok, claims} ->
            email = String.downcase(claims["email"] || "")
            if Store.allowlisted?(email) do
              session_id = random_token()
              mcp_token = random_token()
              Store.put_web_session(session_id, %{email: email, subject: claims["sub"], mcp_token: mcp_token, created_at: System.system_time(:second)})
              Store.put_mcp_token(mcp_token, %{email: email, subject: claims["sub"], session_id: session_id})
              conn
              |> put_resp_cookie("gw_session", session_id, http_only: true, same_site: "Lax", path: "/")
              |> redirect("/")
            else
              html(conn, 403, login_html("Email not allowed: #{email}"))
            end

          {:error, reason} ->
            Logger.warning("google login failed: #{inspect(reason)}")
            html(conn, 401, login_html("Google login failed."))
        end
    end
  end

  post "/logout" do
    with_user(conn, fn conn, user ->
      Store.delete_web_session(user.session_id)
      if user.mcp_token, do: Store.delete_mcp_token(user.mcp_token)
      conn
      |> delete_resp_cookie("gw_session", path: "/")
      |> redirect("/login")
    end)
  end

  # UI actions
  post "/ui/upstreams" do
    with_user(conn, fn conn, _user ->
      name = param(conn, "name")
      url = param(conn, "url")
      auth_type = param(conn, "auth_type") || "none"
      bearer = param(conn, "bearer_token")

      cond do
        !valid_name?(name) -> html(conn, 400, error_page("Invalid upstream name."))
        !valid_url?(url) -> html(conn, 400, error_page("Invalid upstream URL."))
        true ->
          auth = case auth_type do
            "bearer" -> %{type: "bearer", token: bearer || ""}
            _ -> %{type: "none"}
          end
          up = %{name: name, url: url, auth: auth, status: "configured", mcp_session_id: nil}
          Store.put_upstream(name, up)
          up = refresh_upstream(up)
          Store.put_upstream(name, up)
          redirect(conn, "/")
      end
    end)
  end

  post "/ui/upstreams/:name/delete" do
    with_user(conn, fn conn, _user ->
      Store.delete_upstream(name)
      redirect(conn, "/")
    end)
  end

  post "/ui/upstreams/:name/refresh" do
    with_user(conn, fn conn, _user ->
      if up = Store.get_upstream(name) do
        Store.put_upstream(name, refresh_upstream(up))
      end
      redirect(conn, "/")
    end)
  end

  post "/ui/toggle" do
    with_user(conn, fn conn, _user ->
      upstream = param(conn, "upstream")
      tool = param(conn, "tool")
      value = param(conn, "value") == "true"
      if upstream && tool, do: Store.set_allowed(upstream, tool, value)
      redirect(conn, "/")
    end)
  end

  # Upstream OAuth (initiated only from web UI)
  post "/ui/upstreams/:name/oauth/start" do
    with_user(conn, fn conn, _user ->
      case Store.get_upstream(name) do
        %{oauth: oauth} = up when is_map(oauth) ->
          state = random_token()
          Store.put_upstream_oauth_state(state, %{upstream: name, inserted_at: System.system_time(:second)})
          redirect(conn, upstream_authorize_url(up, state))
        _ ->
          html(conn, 400, error_page("Upstream '#{name}' has no OAuth configuration. Configure auth_url, token_url, client_id, client_secret, redirect_uri/scope via upstream settings."))
      end
    end)
  end

  get "/auth/upstream/callback" do
    code = conn.params["code"]
    state = conn.params["state"]
    saved = state && Store.pop_upstream_oauth_state(state)
    cond do
      is_nil(saved) -> html(conn, 400, error_page("Invalid or expired upstream OAuth state."))
      true ->
        name = saved.upstream
        case Store.get_upstream(name) do
          nil -> html(conn, 404, error_page("Unknown upstream."))
          up ->
            case exchange_upstream_code(up, code) do
              {:ok, token_resp} ->
                auth = %{type: "oauth", access_token: token_resp["access_token"], refresh_token: token_resp["refresh_token"], token_type: token_resp["token_type"]}
                up = Map.put(up, :auth, auth) |> Map.put(:status, "oauth connected")
                up = refresh_upstream(up)
                Store.put_upstream(name, up)
                redirect(conn, "/")
              {:error, reason} ->
                Logger.warning("upstream oauth failed for #{name}: #{inspect(reason)}")
                html(conn, 400, error_page("Upstream OAuth failed."))
            end
        end
    end
  end

  post "/ui/upstreams/:name/oauth/config" do
    with_user(conn, fn conn, _user ->
      case Store.get_upstream(name) do
        nil -> html(conn, 404, error_page("Unknown upstream."))
        up ->
          oauth = %{
            auth_url: param(conn, "oauth_auth_url"),
            token_url: param(conn, "oauth_token_url"),
            client_id: param(conn, "oauth_client_id"),
            client_secret: param(conn, "oauth_client_secret"),
            scope: param(conn, "oauth_scope") || ""
          }
          up = Map.put(up, :oauth, oauth) |> Map.put(:auth, %{type: "oauth_pending"})
          Store.put_upstream(name, up)
          redirect(conn, "/")
      end
    end)
  end

  # --- MCP endpoint (Streamable HTTP) ---
  post "/mcp" do
    case mcp_user(conn) do
      {:ok, user} ->
        handle_mcp(conn, user)
      {:error, status, msg} ->
        send_json(conn, status, %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32001, "message" => msg}})
    end
  end

  get "/mcp" do
    send_resp(conn, 405, "")
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  # --- MCP handling ---
  defp handle_mcp(conn, user) do
    body = conn.body_params
    cond do
      !is_map(body) or body["jsonrpc"] != "2.0" or !is_binary(body["method"]) ->
        send_mcp(conn, 400, %{"jsonrpc" => "2.0", "id" => body_id(body), "error" => %{"code" => -32600, "message" => "Invalid Request"}})
      not Map.has_key?(body, "id") ->
        send_resp(conn, 202, "")
      true ->
        case modern_version(body) do
          v when v in [nil, @modern_version] -> send_mcp(conn, 200, dispatch_mcp(body, user))
          version -> send_mcp(conn, 400, unsupported_version(body, version))
        end
    end
  end

  defp dispatch_mcp(%{"method" => method, "id" => id, "params" => params} = _req, user) do
    params = params || %{}
    case method do
      "initialize" -> ok(id, %{"protocolVersion" => negotiated_version(params), "capabilities" => capabilities(), "serverInfo" => @server_info})
      "server/discover" ->
        ok(id, cached(%{
          "supportedVersions" => @supported_versions,
          "capabilities" => capabilities(),
          "_meta" => %{"io.modelcontextprotocol/serverInfo" => @server_info}
        }))
      "ping" -> ok(id, %{})
      "tools/list" -> ok(id, cached(%{"tools" => all_mcp_tools()}))
      "tools/call" -> call_mcp_tool(id, params, user)
      "skills/list" -> ok(id, %{"skills" => Local.list_skills()})
      "skills/get" -> mcp_skill_get(id, params)
      "resources/list" -> ok(id, cached(%{"resources" => skill_resources()}))
      "resources/read" -> mcp_resource_read(id, params)
      _ -> err(id, -32601, "Method not found: #{method}")
    end
  end
  defp dispatch_mcp(%{"method" => method, "id" => id}, user), do: dispatch_mcp(%{"method" => method, "id" => id, "params" => %{}}, user)

  defp call_mcp_tool(id, %{"name" => name} = params, user) when is_binary(name) do
    args = params["arguments"] || %{}
    cond do
      Local.local_tool?(name) ->
        {:ok, tool} = Local.denamespace_tool(name)
        case Local.call_tool(tool, args, %{email: user.email, subject: user[:subject], mcp_authenticated: true}) do
          {:ok, result} -> ok(id, result)
          {:error, msg} -> ok(id, tool_error(msg))
        end

      true ->
        case String.split(name, "__", parts: 2) do
          [upstream, tool] ->
            if Store.get_upstream(upstream) == nil do
              err(id, -32602, "No MCP server named '#{upstream}'")
            else
              if Store.allowed?(upstream, tool) do
                call_remote_tool(id, upstream, tool, args)
              else
                ok(id, tool_error("blocked by policy: #{name}"))
              end
            end
          _ ->
            err(id, -32602, "Tool name must be '<server>__<tool>'")
        end
    end
  end
  defp call_mcp_tool(id, _, _), do: err(id, -32602, "tools/call requires a 'name' parameter")

  defp call_remote_tool(id, upstream_name, tool, args) do
    up = Store.get_upstream(upstream_name)
    case UpstreamHTTP.call_tool(up, tool, args) do
      {:ok, result, sid} ->
        if sid && sid != up.mcp_session_id, do: Store.put_upstream(upstream_name, Map.put(up, :mcp_session_id, sid))
        ok(id, result)
      {:error, reason} ->
        ok(id, tool_error("upstream '#{upstream_name}' failed: #{inspect(reason)}"))
    end
  end

  defp mcp_skill_get(id, %{"uri" => uri}) do
    case Local.get_skill(uri) do
      {:ok, skill} -> ok(id, %{"skill" => skill})
      {:error, _} -> err(id, -32602, "Unknown skill URI: #{uri}")
    end
  end
  defp mcp_skill_get(id, _), do: err(id, -32602, "skills/get requires a 'uri' parameter")

  defp mcp_resource_read(id, %{"uri" => uri}) do
    case Local.read_resource(uri) do
      {:ok, contents} -> ok(id, cached(%{"contents" => contents}))
      {:error, _} -> err(id, -32602, "Unknown resource URI: #{uri}")
    end
  end
  defp mcp_resource_read(id, _), do: err(id, -32602, "resources/read requires a 'uri' parameter")

  defp all_mcp_tools do
    local = Local.tools()
    remote =
      Store.all_tools()
      |> Enum.map(fn {upstream, tool} ->
        Map.put(tool, "name", upstream <> "__" <> (tool["name"] || ""))
      end)
    local ++ remote
  end

  defp capabilities do
    base = %{"tools" => %{"listChanged" => false}}
    if Local.list_skills() == [], do: base, else: Map.merge(base, %{"resources" => %{}, "extensions" => %{"io.modelcontextprotocol/skills" => %{}}})
  end

  defp skill_resources do
    Local.list_skills()
    |> Enum.flat_map(fn skill ->
      Enum.map(skill["resources"] || [], fn file ->
        %{"uri" => file["uri"], "name" => file["name"] || file["uri"], "description" => "file of skill #{get_in(skill, ["frontmatter", "name"]) }"}
      end)
    end)
  end

  defp negotiated_version(params) do
    v = params["protocolVersion"]
    if v in @legacy_versions, do: v, else: @protocol_version
  end

  defp modern_version(%{"params" => %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => v}}}) when is_binary(v), do: v
  defp modern_version(_), do: nil

  defp unsupported_version(body, version) do
    %{"jsonrpc" => "2.0", "id" => body_id(body),
      "error" => %{"code" => -32022, "message" => "Unsupported protocol version",
                   "data" => %{"supported" => @supported_versions, "requested" => version}}}
  end

  # --- auth/helpers ---
  defp current_user(conn) do
    sid = conn.cookies["gw_session"]
    if sid, do: (s = Store.get_web_session(sid)) && Map.put(s, :session_id, sid)
  end

  defp with_user(conn, fun) do
    case current_user(conn) do
      nil -> redirect(conn, "/login")
      user -> fun.(conn, user)
    end
  end

  defp mcp_user(conn) do
    auth = get_req_header(conn, "authorization") |> List.first() || ""
    case auth do
      "Bearer " <> token ->
        case Store.get_mcp_token(String.trim(token)) do
          nil -> {:error, 401, "Invalid or missing bearer token"}
          user -> if Store.allowlisted?(user.email), do: {:ok, user}, else: {:error, 403, "User not allowed"}
        end
      _ -> {:error, 401, "Missing Authorization: Bearer token"}
    end
  end

  defp refresh_upstream(up) do
    case UpstreamHTTP.connect(up) do
      {:ok, %{tools: tools, session_id: sid}} ->
        Store.put_tools(up.name, tools)
        up |> Map.put(:status, "connected") |> Map.put(:mcp_session_id, sid) |> Map.put(:tool_count, length(tools)) |> Map.delete(:error)
      {:error, reason} ->
        Store.put_tools(up.name, [])
        up |> Map.put(:status, "error") |> Map.put(:error, inspect(reason)) |> Map.put(:tool_count, 0)
    end
  end

  defp upstream_authorize_url(up, state) do
    o = up.oauth
    q = URI.encode_query(%{response_type: "code", client_id: o.client_id, redirect_uri: Config.base_url() <> "/auth/upstream/callback", scope: o.scope || "", state: state})
    o.auth_url <> "?" <> q
  end

  defp exchange_upstream_code(up, code) do
    o = up.oauth
    body = %{grant_type: "authorization_code", code: code, redirect_uri: Config.base_url() <> "/auth/upstream/callback", client_id: o.client_id, client_secret: o.client_secret}
    case Req.post(o.token_url, form: body, finch: McpGateway.Finch) do
      {:ok, %{status: 200, body: resp}} when is_map(resp) -> {:ok, resp}
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, r} -> {:error, r}
    end
  end

  defp ok(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => Map.put(result, "resultType", "complete")}
  defp cached(result), do: Map.merge(result, @cache)
  defp err(id, code, msg), do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => msg}}
  defp tool_error(msg), do: %{"content" => [%{"type" => "text", "text" => msg}], "isError" => true}

  defp send_mcp(conn, status, payload) do
    accepts = get_req_header(conn, "accept") |> Enum.join(",")
    json = Jason.encode!(payload)
    if String.contains?(accepts, "text/event-stream") do
      conn |> put_resp_content_type("text/event-stream") |> send_resp(status, "event: message\r\ndata: #{json}\r\n\r\n")
    else
      conn |> put_resp_content_type("application/json") |> send_resp(status, json)
    end
  end

  defp send_json(conn, status, payload), do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(payload))

  defp html(conn, status, body) do
    conn |> put_resp_content_type("text/html") |> send_resp(status, body)
  end

  defp redirect(conn, to) do
    conn |> put_resp_header("location", to) |> send_resp(302, "")
  end

  defp random_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  defp param(conn, key), do: conn.params[key] || conn.params[to_string(key)]
  defp body_id(%{"id" => id}), do: id
  defp body_id(_), do: nil
  defp valid_name?(name), do: is_binary(name) and Regex.match?(~r/^[a-zA-Z0-9_-]{1,64}$/, name)
  defp valid_url?(url), do: is_binary(url) and (String.starts_with?(url, "http://") or String.starts_with?(url, "https://"))

  # --- HTML (tiny server-rendered UI) ---
  defp layout(title, inner) do
    """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{esc(title)}</title>
    <style>
    body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;margin:24px;color:#111;background:#fafafa}
    .card{background:#fff;border:1px solid #ddd;border-radius:8px;padding:16px;margin:12px 0}
    table{border-collapse:collapse;width:100%} th,td{border-bottom:1px solid #eee;padding:8px;text-align:left;vertical-align:top}
    input,select{padding:6px;margin:2px} button{padding:6px 10px;margin:2px;cursor:pointer}
    .muted{color:#666;font-size:13px} .ok{color:#0a7} .err{color:#c33} code{background:#f2f2f2;padding:2px 4px;border-radius:4px}
    .row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
    </style></head><body>#{inner}</body></html>
    """
  end

  defp login_html(error) do
    err = if error, do: "<p class=\"err\">#{esc(error)}</p>", else: ""
    layout("MCP Gateway - Login", """
    <h1>MCP Gateway</h1>
    <div class="card"><h2>Login</h2>#{err}
    <form method="post" action="/auth/google"><button type="submit">Sign in with Google</button></form>
    <p class="muted">Allowed emails are controlled by the gateway allowlist file.</p></div>
    """)
  end

  defp dashboard_html(user) do
    upstreams = Store.list_upstreams()
    skills = Local.list_skills()
    layout("MCP Gateway", """
    <div class="row"><h1 style="margin:0">MCP Gateway</h1><div style="flex:1"></div>
      <span class="muted">#{esc(user.email)}</span>
      <form method="post" action="/logout"><button type="submit">Logout</button></form></div>

    <div class="card"><h2>MCP Access</h2>
      <p>Endpoint: <code>#{esc(Config.base_url())}/mcp</code> (Streamable HTTP, bearer token required)</p>
      <p>Bearer token for this session: <code>#{esc(user.mcp_token || "")}</code></p>
      <p class="muted">Use as <code>Authorization: Bearer &lt;token&gt;</code>. Token is in-memory and invalid after logout/restart.</p></div>

    <div class="card"><h2>Local MCP Tools</h2>
      <ul><li><code>local__whoami</code> - diagnostic identity (MCP tool)</li><li><code>local__datetime</code> - current date/time (MCP tool)</li></ul></div>

    <div class="card"><h2>Filesystem Skills (SEP-2640)</h2>
      #{if skills == [], do: "<p class='muted'>No skills found in <code>#{esc(Config.skills_dir())}</code>.</p>", else: "<ul>" <> Enum.map_join(skills, "", fn s -> "<li><code>#{esc(s["uri"])}</code> - #{esc(get_in(s, ["frontmatter", "description"]) || "")}</li>" end) <> "</ul>"}
      <p class="muted">Skills are loaded from files on disk. Copy skill folders/files into the skills directory.</p></div>

    <div class="card"><h2>Add / Update Upstream MCP (HTTP)</h2>
      <form method="post" action="/ui/upstreams" class="row">
        <input name="name" placeholder="name (e.g. remote1)" required>
        <input name="url" placeholder="https://host/mcp" style="width:320px" required>
        <select name="auth_type"><option value="none">no auth</option><option value="bearer">bearer token</option></select>
        <input name="bearer_token" placeholder="bearer token (if used)" style="width:220px">
        <button type="submit">Save & Connect</button>
      </form>
      <p class="muted">For upstreams that need OAuth, save the upstream first, then configure OAuth and click Connect OAuth (flows run from this web UI only).</p></div>

    #{Enum.map_join(upstreams, "", &upstream_card/1)}
    """)
  end

  defp upstream_card(up) do
    tools = Store.get_tools(up.name)
    policy = Store.policy_for(up.name)
    status_class = if up.status == "connected" or up.status == "oauth connected", do: "ok", else: "err"
    tool_rows = if tools == [] do
      "<tr><td colspan='3' class='muted'>No tools discovered.</td></tr>"
    else
      Enum.map_join(tools, "", fn t ->
        tname = t["name"] || ""
        full = up.name <> "__" <> tname
        allowed = Map.get(policy, tname, true)
        btn = if allowed do
          ~s(<form method="post" action="/ui/toggle" style="display:inline"><input type="hidden" name="upstream" value="#{esc(up.name)}"><input type="hidden" name="tool" value="#{esc(tname)}"><input type="hidden" name="value" value="false"><button type="submit">Block</button></form>)
        else
          ~s(<form method="post" action="/ui/toggle" style="display:inline"><input type="hidden" name="upstream" value="#{esc(up.name)}"><input type="hidden" name="tool" value="#{esc(tname)}"><input type="hidden" name="value" value="true"><button type="submit">Allow</button></form>)
        end
        state = if allowed, do: "<span class='ok'>allowed</span>", else: "<span class='err'>blocked</span>"
        "<tr><td><code>#{esc(full)}</code></td><td>#{esc(t["description"] || "")}</td><td>#{state} #{btn}</td></tr>"
      end)
    end

    oauth = up[:oauth] || %{}
    """
    <div class="card"><h2>Upstream: #{esc(up.name)}</h2>
      <p>URL: <code>#{esc(up.url)}</code> | Status: <span class="#{status_class}">#{esc(to_string(up.status))}</span></p>
      #{if up[:error], do: "<p class='err'>#{esc(to_string(up.error))}</p>", else: ""}
      <div class="row">
        <form method="post" action="/ui/upstreams/#{esc(up.name)}/refresh"><button type="submit">Refresh Tools</button></form>
        <form method="post" action="/ui/upstreams/#{esc(up.name)}/delete"><button type="submit">Remove</button></form>
      </div>
      <details><summary>OAuth configuration (web UI only)</summary>
        <form method="post" action="/ui/upstreams/#{esc(up.name)}/oauth/config">
          <div class="row"><input name="oauth_auth_url" placeholder="auth URL" value="#{esc(oauth[:auth_url] || "")}" style="width:320px">
          <input name="oauth_token_url" placeholder="token URL" value="#{esc(oauth[:token_url] || "")}" style="width:320px"></div>
          <div class="row"><input name="oauth_client_id" placeholder="client id" value="#{esc(oauth[:client_id] || "")}">
          <input name="oauth_client_secret" placeholder="client secret" value="#{esc(oauth[:client_secret] || "")}">
          <input name="oauth_scope" placeholder="scope" value="#{esc(oauth[:scope] || "")}"></div>
          <button type="submit">Save OAuth Config</button>
        </form>
        <form method="post" action="/ui/upstreams/#{esc(up.name)}/oauth/start"><button type="submit">Connect OAuth (open provider)</button></form>
        <p class="muted">Callback: <code>#{esc(Config.base_url())}/auth/upstream/callback</code></p>
      </details>
      <h3>Functions / Toggles (default: allowed)</h3>
      <table><tr><th>Tool</th><th>Description</th><th>Policy</th></tr>#{tool_rows}</table>
    </div>
    """
  end

  defp error_page(msg), do: layout("Error", "<div class='card'><p class='err'>#{esc(msg)}</p><p><a href='/'>Back</a></p></div>")

  defp esc(nil), do: ""
  defp esc(val) do
    val |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;") |> String.replace("\"", "&quot;")
  end
end

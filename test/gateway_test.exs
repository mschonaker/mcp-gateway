defmodule McpGateway.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias McpGateway.{Router, Store}

  @token "test-mcp-token"

  setup do
    Store.put_mcp_token(@token, %{
      email: "mschonaker@gmail.com",
      subject: "test-subject",
      session_id: "test-session"
    })

    on_exit(fn ->
      Store.delete_mcp_token(@token)
      Store.delete_upstream("fake")
    end)

    :ok
  end

  test "MCP endpoint requires a bearer token" do
    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}, [])
    assert conn.status == 401
  end

  test "tools/list exposes local tools" do
    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    assert conn.status == 200
    names = json(conn)["result"]["tools"] |> Enum.map(& &1["name"])
    assert "local__whoami" in names
    assert "local__datetime" in names
  end

  test "tools/list exposes configured upstream tools with namespacing" do
    Store.put_upstream("fake", %{
      name: "fake",
      url: "http://localhost:1/mcp",
      auth: %{type: "none"},
      status: "connected",
      mcp_session_id: nil
    })

    Store.put_tools("fake", [%{"name" => "echo", "description" => "echo"}])

    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    names = json(conn)["result"]["tools"] |> Enum.map(& &1["name"])
    assert "fake__echo" in names
  end

  test "local whoami returns the authenticated identity" do
    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "local__whoami", "arguments" => %{}}
      })

    [%{"text" => text}] = json(conn)["result"]["content"]
    assert Jason.decode!(text)["email"] == "mschonaker@gmail.com"
  end

  test "blocked upstream calls do not reach the network" do
    Store.put_upstream("fake", %{
      name: "fake",
      url: "http://localhost:1/mcp",
      auth: %{type: "none"},
      status: "connected",
      mcp_session_id: nil
    })

    Store.put_tools("fake", [%{"name" => "echo"}])
    Store.set_allowed("fake", "echo", false)

    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "fake__echo", "arguments" => %{}}
      })

    result = json(conn)["result"]
    assert result["isError"] == true
    assert hd(result["content"])["text"] =~ "blocked by policy"

    Store.set_allowed("fake", "echo", true)
  end

  test "blocked local tools do not execute" do
    Store.set_allowed("local:tools", "whoami", false)
    on_exit(fn -> Store.set_allowed("local:tools", "whoami", true) end)

    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "local__whoami", "arguments" => %{}}
      })

    result = json(conn)["result"]
    assert result["isError"] == true
    assert hd(result["content"])["text"] =~ "blocked by policy"
  end

  test "blocked skills are hidden and cannot be read" do
    uri = "skill://whoami-check/SKILL.md"
    Store.set_allowed("local:skills", "whoami-check", false)
    on_exit(fn -> Store.set_allowed("local:skills", "whoami-check", true) end)

    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => "skills/list"})
    refute uri in (json(conn)["result"]["skills"] |> Enum.map(& &1["uri"]))

    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/list"})
    uris = json(conn)["result"]["resources"] |> Enum.map(& &1["uri"])
    refute Enum.any?(uris, &String.starts_with?(&1, "skill://whoami-check/"))

    for method <- ["skills/get", "resources/read"] do
      conn =
        post_mcp(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => method,
          "params" => %{"uri" => uri}
        })

      assert json(conn)["error"]["message"] =~ "blocked by policy"
    end
  end

  test "server/discover advertises the modern protocol version" do
    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "server/discover",
        "params" => %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}}
      })

    result = json(conn)["result"]
    assert "2026-07-28" in result["supportedVersions"]
    assert result["resultType"] == "complete"
    assert result["ttlMs"] == 0
    assert result["cacheScope"] == "private"
    assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "mcp-gateway"
  end

  test "modern results carry cache metadata" do
    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}}
      })

    result = json(conn)["result"]
    assert result["resultType"] == "complete"
    assert result["ttlMs"] == 0
    assert result["cacheScope"] == "private"
  end

  test "unsupported modern protocol version is rejected" do
    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "1900-01-01"}}
      })

    assert conn.status == 400
    assert json(conn)["error"]["code"] == -32022
    assert "2026-07-28" in json(conn)["error"]["data"]["supported"]
  end

  test "skills/list serves filesystem skills" do
    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => "skills/list"})
    uris = json(conn)["result"]["skills"] |> Enum.map(& &1["uri"])
    assert "skill://whoami-check/SKILL.md" in uris
  end

  test "skills/get returns a skill manifest" do
    conn =
      post_mcp(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "skills/get",
        "params" => %{"uri" => "skill://whoami-check/SKILL.md"}
      })

    assert json(conn)["result"]["skill"]["uri"] == "skill://whoami-check/SKILL.md"
  end

  test "dashboard shows harness setup commands" do
    Store.put_upstream("fake", %{
      name: "fake",
      url: "http://localhost:1/mcp",
      auth: %{type: "none"},
      status: "connected",
      mcp_session_id: nil,
      oauth: %{client_secret: "top-secret"}
    })

    conn = web_request(:get, "/")

    assert conn.status == 200
    assert conn.resp_body =~ "opencode mcp add gateway --global"
    assert conn.resp_body =~ "codex mcp add gateway"
    assert conn.resp_body =~ "claude mcp add --transport http gateway"
    assert conn.resp_body =~ "copilot mcp add --transport http"
    assert conn.resp_body =~ "gemini mcp add --transport http"

    card = conn.resp_body |> String.split("</div>") |> Enum.find(&String.contains?(&1, "Local MCP Tools"))
    assert card != nil
    assert card =~ "Add / Update Upstream MCP (HTTP)"
    assert card =~ "Upstream: fake"
    assert conn.resp_body =~ ~r(name="upstream" value="local:tools")
    assert conn.resp_body =~ ~r(name="upstream" value="local:skills")
    assert conn.resp_body =~ "skill://whoami-check/SKILL.md"
    refute conn.resp_body =~ "top-secret"
  end

  test "upstream OAuth start sends a PKCE challenge" do
    Store.put_upstream("fake", %{
      name: "fake",
      url: "https://api.githubcopilot.com/mcp/",
      auth: %{type: "none"},
      status: "configured",
      mcp_session_id: nil,
      oauth: %{auth_url: "https://github.com/login/oauth/authorize", client_id: "cid"}
    })

    conn = web_request(:post, "/ui/upstreams/fake/oauth/start")
    assert conn.status == 302

    location = conn |> get_resp_header("location") |> hd()
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["code_challenge_method"] == "S256"

    saved = Store.pop_upstream_oauth_state(query["state"])
    assert saved.upstream == "fake"
    assert byte_size(saved.verifier) == 43

    expected = :crypto.hash(:sha256, saved.verifier) |> Base.url_encode64(padding: false)
    assert query["code_challenge"] == expected
  end

  test "saving OAuth config keeps the stored secret and existing auth" do
    Store.put_upstream("fake", %{
      name: "fake",
      url: "https://api.githubcopilot.com/mcp/",
      auth: %{type: "oauth", access_token: "old-token"},
      status: "oauth connected",
      mcp_session_id: nil,
      oauth: %{client_secret: "top-secret"}
    })

    conn =
      web_request(:post, "/ui/upstreams/fake/oauth/config", %{
        "oauth_auth_url" => "https://github.com/login/oauth/authorize",
        "oauth_token_url" => "https://github.com/login/oauth/access_token",
        "oauth_client_id" => "cid",
        "oauth_client_secret" => "",
        "oauth_scope" => "repo read:user"
      })

    assert conn.status == 302
    up = Store.get_upstream("fake")
    assert up.oauth.client_secret == "top-secret"
    assert up.auth == %{type: "oauth", access_token: "old-token"}
  end

  defp web_request(method, path, params \\ nil) do
    session_id = "test-web-session"

    Store.put_web_session(session_id, %{
      email: "mschonaker@gmail.com",
      subject: "test-subject",
      mcp_token: @token,
      created_at: 0
    })

    on_exit(fn -> Store.delete_web_session(session_id) end)

    conn = if params, do: conn(method, path, params), else: conn(method, path)
    conn |> put_req_cookie("gw_session", session_id) |> Router.call(Router.init([]))
  end

  defp post_mcp(body, headers \\ [{"authorization", "Bearer #{@token}"}]) do
    conn(:post, "/mcp", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_headers(headers)
    |> Router.call(Router.init([]))
  end

  defp put_req_headers(conn, headers), do: Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

  defp json(conn), do: Jason.decode!(conn.resp_body)
end

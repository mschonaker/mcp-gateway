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

  test "skills/list carries cache metadata" do
    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 1, "method" => "skills/list"})
    result = json(conn)["result"]
    assert result["resultType"] == "complete"
    assert result["ttlMs"] == 0
    assert result["cacheScope"] == "private"
  end

  test "skill catalog index lists skills with a version and files" do
    conn = get_public("/skills/index.json")
    assert conn.status == 200

    entry = json(conn)["skills"] |> Enum.find(&(&1["name"] == "datetime-now"))
    assert "SKILL.md" in entry["files"]
    assert is_binary(entry["version"])
  end

  test "skill catalog serves a skill file without authentication" do
    conn = get_public("/skills/datetime-now/SKILL.md")
    assert conn.status == 200
    assert conn.resp_body =~ "name: datetime-now"
  end

  test "skill catalog rejects paths outside the skills directory" do
    assert get_public("/skills/datetime-now/../../config/allowlist.txt").status == 404
  end

  defp get_public(path), do: conn(:get, path) |> Router.call(Router.init([]))

  defp post_mcp(body, headers \\ [{"authorization", "Bearer #{@token}"}]) do
    conn(:post, "/mcp", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_headers(headers)
    |> Router.call(Router.init([]))
  end

  defp put_req_headers(conn, headers), do: Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

  defp json(conn), do: Jason.decode!(conn.resp_body)
end

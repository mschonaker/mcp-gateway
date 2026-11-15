defmodule McpGatewayTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias McpGateway.{Router, Sessions, Upstream}

  @script_path Path.expand("../priv/fake_mcp_server.exs", __DIR__)

  setup do
    ensure_upstream("fake")
    # Blocks until the upstream handshake, tools/list, and skills/list complete.
    assert length(Upstream.list_tools("fake")) == 2
    assert length(Upstream.list_skills("fake")) == 1
    :ok
  end

  describe "initialize" do
    test "creates a session and reports gateway capabilities" do
      conn = rpc("initialize", initialize_params()) |> request()
      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")
      assert Sessions.known?(session_id)

      assert %{"result" => result} = json_body(conn)
      assert result["protocolVersion"] == "2025-03-26"
      assert result["serverInfo"]["name"] == "elixir-mcp-gateway"
    end

    test "echoes a supported protocol version" do
      conn = rpc("initialize", initialize_params("2024-11-05")) |> request()
      assert json_body(conn)["result"]["protocolVersion"] == "2024-11-05"
    end

    test "falls back to the newest supported version" do
      conn = rpc("initialize", initialize_params("1999-01-01")) |> request()
      assert json_body(conn)["result"]["protocolVersion"] == "2025-03-26"
    end
  end

  describe "session enforcement" do
    test "requests without a session id are rejected" do
      conn = rpc("tools/list") |> request()
      assert conn.status == 400
      assert json_body(conn)["error"]["code"] == -32600
    end

    test "unknown session ids are rejected" do
      conn = rpc("tools/list", %{}, 2, "bogus-session") |> request()
      assert conn.status == 404
    end

    test "DELETE terminates the session" do
      session = initialize()

      conn =
        conn(:delete, "/mcp")
        |> put_req_header("mcp-session-id", session)
        |> Router.call(Router.init([]))

      assert conn.status == 200
      refute Sessions.known?(session)
      assert request(rpc("tools/list", %{}, 3, session)).status == 404
    end
  end

  describe "tools/list" do
    test "aggregates namespaced tools from all upstreams" do
      ensure_upstream("second")
      conn = session_request("tools/list")
      tools = json_body(conn)["result"]["tools"]

      names = Enum.map(tools, & &1["name"])
      assert "fake__echo" in names
      assert "fake__boom" in names
      assert "second__echo" in names
    end
  end

  describe "tools/call" do
    test "routes by namespace prefix and passes arguments through" do
      conn =
        session_request("tools/call", %{"name" => "fake__echo", "arguments" => %{"text" => "hi"}})

      assert %{"result" => %{"content" => [%{"text" => text}]}} = json_body(conn)
      assert text == "echo:echo:hi"
    end

    test "normalizes upstream JSON-RPC errors into isError results" do
      conn = session_request("tools/call", %{"name" => "fake__boom"})
      assert %{"result" => result} = json_body(conn)
      assert result["isError"] == true
      refute Map.has_key?(json_body(conn), "error")
    end

    test "rejects un-namespaced tool names" do
      conn = session_request("tools/call", %{"name" => "echo"})
      assert json_body(conn)["error"]["code"] == -32602
    end

    test "reports unknown servers" do
      conn = session_request("tools/call", %{"name" => "nosuch__echo"})
      assert json_body(conn)["error"]["code"] == -32602
    end
  end

  describe "skills extension" do
    test "initialize advertises the extension only because an upstream serves skills" do
      conn = rpc("initialize", initialize_params()) |> request()
      caps = json_body(conn)["result"]["capabilities"]
      assert get_in(caps, ["extensions", "io.modelcontextprotocol/skills"]) == %{}
      assert Map.has_key?(caps, "resources")
    end

    test "skills/list returns namespaced entries with full manifests" do
      conn = session_request("skills/list")

      skill =
        json_body(conn)["result"]["skills"]
        |> Enum.find(&(&1["uri"] == "skill://fake__greet/SKILL.md"))

      assert skill["frontmatter"]["name"] == "fake__greet"
      assert skill["frontmatter"]["description"] == "Greet someone warmly."

      uris = Enum.map(skill["resources"], & &1["uri"])
      assert uris == ["skill://fake__greet/SKILL.md", "skill://fake__greet/references/usage.md"]
    end

    test "skills/get rewrites a single entry" do
      conn = session_request("skills/get", %{"uri" => "skill://fake__greet/SKILL.md"})
      assert json_body(conn)["result"]["skill"]["uri"] == "skill://fake__greet/SKILL.md"
    end

    test "skills/get unknown uri returns a -32602 protocol error" do
      conn = session_request("skills/get", %{"uri" => "skill://fake__nope/SKILL.md"})
      assert json_body(conn)["error"]["code"] == -32602
    end

    test "resources/list catalogs every manifest file" do
      conn = session_request("resources/list")
      uris = json_body(conn)["result"]["resources"] |> Enum.map(& &1["uri"])
      assert "skill://fake__greet/SKILL.md" in uris
      assert "skill://fake__greet/references/usage.md" in uris
    end

    test "read content verifies against the published digest" do
      listed = session_request("skills/list") |> json_body()

      skill =
        listed["result"]["skills"]
        |> Enum.find(&(&1["uri"] == "skill://fake__greet/SKILL.md"))

      conn =
        session_request("resources/read", %{"uri" => "skill://fake__greet/references/usage.md"})

      [%{"uri" => uri, "text" => text} | _] = json_body(conn)["result"]["contents"]
      assert uri == "skill://fake__greet/references/usage.md"

      digest = "sha256:" <> (:crypto.hash(:sha256, text) |> Base.encode16(case: :lower))
      published = Enum.find(skill["resources"], &(&1["uri"] == uri))
      assert published["digest"] == digest
      assert published["size"] == byte_size(text)
    end

    test "skills from two upstreams coexist under distinct uris" do
      ensure_upstream("second")
      conn = session_request("skills/list")

      uris =
        conn
        |> json_body()
        |> get_in(["result", "skills"])
        |> Enum.map(& &1["uri"])
        |> Enum.sort()

      assert uris == ["skill://fake__greet/SKILL.md", "skill://second__greet/SKILL.md"]
    end
  end

  describe "protocol surface" do
    test "notifications are accepted with 202" do
      conn =
        conn(
          :post,
          "/mcp",
          Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-session-id", initialize())
        |> Router.call(Router.init([]))

      assert conn.status == 202
    end

    test "unknown methods return method-not-found" do
      conn = session_request("tools/shuffle")
      assert json_body(conn)["error"]["code"] == -32601
    end

    test "batch requests are rejected" do
      conn =
        conn(:post, "/mcp", Jason.encode!([%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}]))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 400
    end

    test "SSE is used when the client accepts it" do
      conn =
        rpc("ping")
        |> Map.update!(:req_headers, &(&1 ++ [{"accept", "application/json, text/event-stream"}]))
        |> with_session()
        |> Router.call(Router.init([]))

      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/event-stream"
      assert conn.resp_body =~ "event: message\r\ndata: {"
    end

    test "GET /mcp offers no stream" do
      assert request_conn(conn(:get, "/mcp")).status == 405
    end

    test "GET /health is live" do
      conn = request_conn(conn(:get, "/health"))
      assert conn.status == 200
      assert conn.resp_body == "ok"
    end
  end

  # --- helpers ---

  defp ensure_upstream(name) do
    if Registry.lookup(McpGateway.Upstreams, name) == [] do
      {:ok, _} =
        DynamicSupervisor.start_child(McpGateway.UpstreamSupervisor, {
          Upstream,
          name: name, command: "elixir", args: [@script_path]
        })
    end

    :ok
  end

  defp initialize_params(version \\ "2025-03-26") do
    %{
      "protocolVersion" => version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "test-client", "version" => "0"}
    }
  end

  defp rpc(method, params \\ %{}, id \\ 1, session \\ nil) do
    body = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    conn = conn(:post, "/mcp", Jason.encode!(body))
    conn = put_req_header(conn, "content-type", "application/json")
    conn = put_req_header(conn, "accept", "application/json")

    if session do
      put_req_header(conn, "mcp-session-id", session)
    else
      conn
    end
  end

  defp request(conn), do: Router.call(conn, Router.init([]))

  defp request_conn(conn), do: Router.call(conn, Router.init([]))

  defp initialize do
    conn = rpc("initialize", initialize_params()) |> request()
    [session] = get_resp_header(conn, "mcp-session-id")
    session
  end

  defp with_session(conn) do
    put_req_header(conn, "mcp-session-id", initialize())
  end

  defp session_request(method, params \\ %{}) do
    rpc(method, params) |> with_session() |> request()
  end

  defp json_body(conn), do: Jason.decode!(IO.iodata_to_binary(conn.resp_body || conn.body_params))
end

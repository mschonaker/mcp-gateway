defmodule McpGateway.Router do
  @moduledoc """
  Streamable HTTP endpoint for MCP clients.

  POST /mcp     JSON-RPC 2.0 (application/json or text/event-stream replies)
  DELETE /mcp   terminate an Mcp-Session-Id
  GET /mcp      405: the gateway offers no server-initiated SSE stream
  GET /health   liveness probe
  """
  use Plug.Router
  require Logger

  alias McpGateway.{Sessions, Upstream}

  @protocol_version "2025-03-26"
  @supported_versions ["2024-11-05", "2025-03-26"]
  @server_info %{"name" => "elixir-mcp-gateway", "version" => "0.1.0"}

  plug(Plug.Logger)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    body = conn.body_params
    session = get_req_header(conn, "mcp-session-id") |> List.first()

    cond do
      invalid_request?(body) ->
        send_rpc(conn, 400, error(body_id(body), -32600, "Invalid Request"))

      is_binary(session) and not Sessions.known?(session) ->
        send_rpc(conn, 404, error(body_id(body), -32600, "Unknown or expired session"))

      method(body) == "initialize" ->
        new_session = Sessions.create()

        conn
        |> put_resp_header("mcp-session-id", new_session)
        |> send_rpc(200, result(body_id(body), initialize_result(body)))

      require_session?() and is_nil(session) ->
        send_rpc(conn, 400, error(body_id(body), -32600, "Missing Mcp-Session-Id header"))

      notification?(body) ->
        send_resp(conn, 202, "")

      true ->
        send_rpc(conn, 200, handle_rpc(body))
    end
  end

  delete "/mcp" do
    case get_req_header(conn, "mcp-session-id") |> List.first() do
      session when is_binary(session) ->
        if Sessions.known?(session) do
          Sessions.delete(session)
          send_resp(conn, 200, "")
        else
          send_resp(conn, 404, "")
        end

      _ ->
        send_resp(conn, 400, "")
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

  defp handle_rpc(%{"method" => method} = req) do
    id = req["id"]
    params = req["params"] || %{}

    case method do
      "ping" -> result(id, %{})
      "tools/list" -> result(id, %{"tools" => all_tools()})
      "tools/call" -> call_tool(id, params)
      _ -> error(id, -32601, "Method not found: #{method}")
    end
  end

  defp call_tool(id, %{"name" => namespaced} = params) when is_binary(namespaced) do
    arguments = params["arguments"] || %{}

    case String.split(namespaced, "__", parts: 2) do
      [server, tool] ->
        cond do
          Registry.lookup(McpGateway.Upstreams, server) == [] ->
            error(id, -32602, "No MCP server named '#{server}'")

          true ->
            case safe_call(server, tool, arguments) do
              {:ok, %{"result" => result}} ->
                result(id, result)

              {:ok, %{"error" => error}} ->
                result(id, tool_error_result(error))

              {:ok, _malformed} ->
                result(id, tool_error_result(%{"message" => "malformed response from '#{server}'"}))

              {:error, reason} ->
                result(id, tool_error_result(%{"message" => "upstream '#{server}' failed: #{inspect(reason)}"}))
            end
        end

      _ ->
        error(id, -32602, "Tool name must be '<server>__<tool>', got: #{namespaced}")
    end
  end

  defp call_tool(id, _params) do
    error(id, -32602, "tools/call requires a 'name' parameter")
  end

  defp safe_call(server, tool, arguments) do
    try do
      Upstream.call_tool(server, tool, arguments)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp all_tools do
    upstream_names()
    |> Enum.flat_map(fn name ->
      try do
        Upstream.list_tools(name)
      catch
        :exit, reason ->
          Logger.warning("[#{name}] unavailable: #{inspect(reason)}")
          []
      end
    end)
  end

  defp upstream_names do
    Registry.select(McpGateway.Upstreams, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp initialize_result(req) do
    requested = get_in(req, ["params", "protocolVersion"])
    version = if requested in @supported_versions, do: requested, else: @protocol_version

    %{
      "protocolVersion" => version,
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => @server_info
    }
  end

  defp invalid_request?(body) do
    not is_map(body) or body["jsonrpc"] != "2.0" or !is_binary(body["method"])
  end

  defp notification?(body), do: not Map.has_key?(body, "id")

  defp method(body), do: body["method"]

  defp body_id(body) do
    case body do
      %{"id" => id} -> id
      _ -> nil
    end
  end

  defp require_session? do
    Application.get_env(:mcp_gateway, :require_session, true)
  end

  defp result(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  # Per the MCP spec, tool execution failures must arrive as a result with
  # isError, not as a JSON-RPC error. A misbehaving upstream that answers
  # tools/call with a protocol error is normalized here so clients get a
  # recoverable tool failure instead of a hard call failure.
  defp tool_error_result(error) do
    message = error["message"] || Jason.encode!(error)

    %{
      "content" => [%{"type" => "text", "text" => "tool execution failed: #{message}"}],
      "isError" => true
    }
  end

  defp error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp send_rpc(conn, status, payload) do
    accepts = get_req_header(conn, "accept") |> Enum.join(",")
    json = Jason.encode!(payload)

    if String.contains?(accepts, "text/event-stream") do
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(status, "event: message\r\ndata: #{json}\r\n\r\n")
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, json)
    end
  end
end

defmodule McpGateway.UpstreamHTTP do
  @moduledoc false

  @protocol_version "2025-03-26"

  def connect(upstream) do
    state = %{url: upstream.url, auth: upstream[:auth] || %{type: "none"}, session_id: nil}
    with {:ok, state, init} <- initialize(state),
         {:ok, state, tools} <- list_tools_remote(state) do
      {:ok, %{session_id: state.session_id, tools: tools, info: init}}
    end
  end

  def refresh_tools(upstream) do
    state = %{url: upstream.url, auth: upstream[:auth] || %{type: "none"}, session_id: upstream[:mcp_session_id]}
    case list_tools_remote(state) do
      {:ok, state, tools} -> {:ok, %{tools: tools, session_id: state.session_id}}
      err -> err
    end
  end

  def call_tool(upstream, tool, arguments) do
    state = %{url: upstream.url, auth: upstream[:auth] || %{type: "none"}, session_id: upstream[:mcp_session_id]}
    req = %{"jsonrpc" => "2.0", "id" => req_id(), "method" => "tools/call", "params" => %{"name" => tool, "arguments" => arguments || %{}}}
    case rpc(state, req) do
      {:ok, state2, %{"result" => result}} -> {:ok, result, state2.session_id}
      {:ok, state2, %{"error" => err}} -> {:ok, %{"content" => [%{"type" => "text", "text" => "upstream error: #{err["message"] || inspect(err)}"}], "isError" => true}, state2.session_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp initialize(state) do
    req = %{
      "jsonrpc" => "2.0",
      "id" => req_id(),
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "mcp-gateway", "version" => "0.2.0"}
      }
    }

    with {:ok, state, resp} <- rpc(state, req) do
      _ = notify_initialized(state)
      {:ok, state, resp["result"] || %{}}
    end
  end

  defp notify_initialized(state) do
    req = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    _ = rpc(state, req, false)
    :ok
  end

  defp list_tools_remote(state) do
    req = %{"jsonrpc" => "2.0", "id" => req_id(), "method" => "tools/list", "params" => %{}}
    case rpc(state, req) do
      {:ok, state, %{"result" => %{"tools" => tools}}} -> {:ok, state, tools || []}
      {:ok, state, %{"result" => _}} -> {:ok, state, []}
      {:ok, _state, %{"error" => err}} -> {:error, err}
      err -> err
    end
  end

  defp rpc(state, payload, expect_response \\ true) do
    headers = [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}]
    headers = if state.session_id, do: [{"mcp-session-id", state.session_id} | headers], else: headers
    headers = auth_headers(state.auth) ++ headers

    opts = [headers: headers, receive_timeout: 30_000, finch: McpGateway.Finch]
    opts = if expect_response, do: opts, else: opts

    case Req.post(state.url, [json: payload] ++ opts) do
      {:ok, %{status: status, headers: resp_headers, body: body}} when status in 200..299 ->
        sid = get_header(resp_headers, "mcp-session-id") || state.session_id
        state = %{state | session_id: sid}
        if expect_response do
          case decode_body(body, resp_headers) do
            {:ok, msg} -> {:ok, state, msg}
            :empty -> {:ok, state, %{}}
            {:error, e} -> {:error, e}
          end
        else
          {:ok, state, %{}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_body(body, _headers) when is_map(body), do: {:ok, body}
  defp decode_body(body, headers) when is_binary(body) do
    ct = get_header(headers, "content-type") || ""
    cond do
      body == "" -> :empty
      String.contains?(ct, "text/event-stream") -> decode_sse(body)
      true ->
        case Jason.decode(body) do
          {:ok, msg} -> {:ok, msg}
          _ -> {:error, :invalid_json}
        end
    end
  end
  defp decode_body(_, _), do: :empty

  defp decode_sse(body) do
    # take last data event with json object
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(&String.trim_leading(&1, "data:") |> String.trim())
    |> Enum.reject(&(&1 == "" or &1 == "[DONE]"))
    |> Enum.reverse()
    |> Enum.find_value({:error, :no_data}, fn data ->
      case Jason.decode(data) do
        {:ok, msg} -> {:ok, msg}
        _ -> nil
      end
    end)
  end

  defp auth_headers(%{type: "bearer", token: token}) when is_binary(token) and token != "" do
    [{"authorization", "Bearer " <> token}]
  end
  defp auth_headers(%{type: "oauth", access_token: token}) when is_binary(token) and token != "" do
    [{"authorization", "Bearer " <> token}]
  end
  defp auth_headers(_), do: []

  defp get_header(headers, name) when is_map(headers) do
    lname = String.downcase(name)
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) -> if String.downcase(k) == lname, do: header_value(v)
      {k, v} when is_atom(k) -> if String.downcase(to_string(k)) == lname, do: header_value(v)
      _ -> nil
    end)
  end
  defp get_header(headers, name) when is_list(headers) do
    lname = String.downcase(name)
    Enum.find_value(headers, fn
      {k, v} -> if String.downcase(to_string(k)) == lname, do: header_value(v)
      _ -> nil
    end)
  end
  defp get_header(_, _), do: nil

  defp header_value([v | _]), do: to_string(v)
  defp header_value(v), do: to_string(v)

  defp req_id, do: System.unique_integer([:positive])
end

defmodule FakeMCPServer do
  @moduledoc """
  Minimal stdio MCP server used only by the test suite.

  Reads line-delimited JSON-RPC on stdin, answers initialize, tools/list,
  ping, and tools/call for two tools: echo and boom. Fields are extracted
  with regexes so the script needs no JSON library.
  """

  def run do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        handle(String.trim_trailing(line, "\n"))
        run()
    end
  end

  defp handle(line) do
    id = int_field(line, "id")
    method = str_field(line, "method")

    case {method, id} do
      {_, nil} ->
        :ok

      {"initialize", id} ->
        emit(id, %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "serverInfo" => %{"name" => "fake", "version" => "0.1.0"}
        })

      {"tools/list", id} ->
        emit(id, %{
          "tools" => [
            %{
              "name" => "echo",
              "description" => "Echoes its text argument",
              "inputSchema" => %{"type" => "object"}
            },
            %{
              "name" => "boom",
              "description" => "Always returns an error",
              "inputSchema" => %{"type" => "object"}
            }
          ]
        })

      {"tools/call", id} ->
        case {str_field(line, "name"), str_field(line, "text")} do
          {"boom", _} -> emit_error(id, -32603, "boom")
          {tool, text} -> emit(id, %{"content" => [%{"type" => "text", "text" => "echo:#{tool}:#{text}"}]})
        end

      {"ping", id} ->
        emit(id, %{})

      {unknown, id} ->
        emit_error(id, -32601, "Method not found: #{unknown}")
    end

    :continue
  end

  defp int_field(line, key) do
    case Regex.run(~r/"#{key}"\s*:\s*(-?\d+)/, line) do
      [_, value] -> String.to_integer(value)
      _ -> nil
    end
  end

  defp str_field(line, key) do
    case Regex.run(~r/"#{key}"\s*:\s*"([^"]*)"/, line) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp emit(id, result) do
    write(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp emit_error(id, code, message) do
    write(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})
  end

  defp write(payload) do
    IO.binwrite(:stdio, [encode(payload), "\n"])
  end

  defp encode(value) when is_binary(value), do: [?", escape(value), ?"]
  defp encode(value) when is_integer(value), do: Integer.to_string(value)
  defp encode(value) when is_atom(value), do: Atom.to_string(value)

  defp encode(value) when is_map(value) do
    inner = Enum.map(value, fn {k, v} -> [encode(to_string(k)), ?:, encode(v)] end)
    [?{, Enum.intersperse(inner, ?,), ?}]
  end

  defp encode(value) when is_list(value) do
    [?[, Enum.map_intersperse(value, ?,, &encode/1), ?]]
  end

  defp escape(value) do
    value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end
end

FakeMCPServer.run()

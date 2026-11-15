defmodule FakeMCPServer do
  @moduledoc """
  Minimal stdio MCP server used only by the test suite.

  Reads line-delimited JSON-RPC on stdin, answers initialize, tools/list,
  ping, and tools/call for two tools (echo and boom), and serves one skill
  through the io.modelcontextprotocol/skills extension (SEP-2640):
  skills/list, skills/get, resources/list, and resources/read.
  Fields are extracted with regexes so the script needs no JSON library.
  """

  @skill_md "---\nname: greet\ndescription: Greet someone warmly.\n---\n\n# Greet\n\nRead `references/usage.md`, then greet the person.\n"
  @usage_md "Use a friendly tone. Keep greetings under ten words.\n"

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
          "capabilities" => %{"extensions" => %{"io.modelcontextprotocol/skills" => %{}}},
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

      {"skills/list", id} ->
        emit(id, %{"skills" => [skill_entry()]})

      {"skills/get", id} ->
        uri = str_field(line, "uri")

        if skill_covers?(uri) do
          emit(id, %{"skill" => skill_entry()})
        else
          emit_error(id, -32602, "unknown skill: #{uri}")
        end

      {"resources/list", id} ->
        emit(id, %{"resources" => Enum.map(skill_files(), &%{"uri" => &1["uri"], "name" => Path.basename(&1["uri"])})})

      {"resources/read", id} ->
        uri = str_field(line, "uri")

        case Enum.find(skill_files(), &(&1["uri"] == uri)) do
          nil -> emit_error(id, -32602, "unknown resource: #{uri}")
          file -> emit(id, %{"contents" => [%{"uri" => uri, "mimeType" => "text/markdown", "text" => file["content"]}]})
        end

      {"ping", id} ->
        emit(id, %{})

      {unknown, id} ->
        emit_error(id, -32601, "Method not found: #{unknown}")
    end
  end

  defp skill_files do
    [
      %{"uri" => "skill://greet/SKILL.md", "content" => @skill_md},
      %{"uri" => "skill://greet/references/usage.md", "content" => @usage_md}
    ]
  end

  defp skill_entry do
    manifest =
      Enum.map(skill_files(), fn file ->
        %{"uri" => file["uri"], "digest" => digest(file["content"]), "size" => byte_size(file["content"])}
      end)

    %{
      "uri" => "skill://greet/SKILL.md",
      "frontmatter" => %{"name" => "greet", "description" => "Greet someone warmly."},
      "resources" => manifest
    }
  end

  defp skill_covers?(uri) do
    uri == "skill://greet/SKILL.md" or Enum.any?(skill_files(), &(&1["uri"] == uri))
  end

  defp digest(content) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
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
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end

FakeMCPServer.run()

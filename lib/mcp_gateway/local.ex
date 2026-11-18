defmodule McpGateway.Local do
  @moduledoc false

  alias McpGateway.Config

  @server "local"

  def server_name, do: @server

  def tools do
    [
      %{
        "name" => tool_name("whoami"),
        "description" => "Return diagnostic information about the authenticated caller.",
        "inputSchema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      %{
        "name" => tool_name("datetime"),
        "description" => "Return the current date and time.",
        "inputSchema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      }
    ]
  end

  def call_tool("whoami", _args, ctx) do
    info = %{
      email: ctx[:email],
      subject: ctx[:subject],
      auth: "oidc/google",
      mcp_authenticated: ctx[:mcp_authenticated] || false,
      gateway: "mcp_gateway",
      note: "diagnostic identity as seen by the gateway"
    }

    {:ok, text_result(Jason.encode!(info, pretty: true))}
  end

  def call_tool("datetime", _args, _ctx) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    {:ok, text_result(now)}
  end

  def call_tool(name, _args, _ctx), do: {:error, "unknown local tool: #{name}"}

  def tool_name(name), do: @server <> "__" <> name

  def local_tool?(name) do
    Enum.any?(tools(), &(&1["name"] == name))
  end

  def denamespace_tool(@server <> "__" <> name), do: {:ok, name}
  def denamespace_tool(_), do: :error

  # SEP-2640 skills from filesystem
  def list_skills do
    skills_dir()
    |> list_skill_dirs()
    |> Enum.map(&load_skill/1)
    |> Enum.reject(&is_nil/1)
  end

  def get_skill(uri) do
    case uri_to_path(uri) do
      {:ok, _skill_name, path} ->
        if File.regular?(path) do
          skill_name = skill_name_from_uri(uri)
          base = Path.join(skills_dir(), skill_name)
          skill = load_skill(base)
          {:ok, skill}
        else
          {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def read_resource(uri) do
    case uri_to_path(uri) do
      {:ok, _skill_name, path} ->
        if File.regular?(path) do
          data = File.read!(path)
          content =
            if String.valid?(data) do
              %{"uri" => uri, "mimeType" => mime_type(path), "text" => data}
            else
              %{"uri" => uri, "mimeType" => mime_type(path), "blob" => Base.encode64(data)}
            end

          {:ok, [content]}
        else
          {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp skills_dir, do: Config.skills_dir()

  defp list_skill_dirs(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.filter(&File.regular?(Path.join(&1, "SKILL.md")))

      _ ->
        []
    end
  end

  defp load_skill(skill_dir) do
    skill_name = Path.basename(skill_dir)
    skill_md = Path.join(skill_dir, "SKILL.md")
    text = File.read!(skill_md)
    {frontmatter, _body} = parse_frontmatter(text, skill_name)

    files =
      skill_dir
      |> list_files_recursive()
      |> Enum.map(fn path ->
        rel = Path.relative_to(path, skill_dir)
        uri = "skill://#{skill_name}/#{rel}"
        data = File.read!(path)
        %{
          "uri" => uri,
          "name" => rel,
          "mimeType" => mime_type(path),
          "digest" => "sha256:" <> (:crypto.hash(:sha256, data) |> Base.encode16(case: :lower)),
          "size" => byte_size(data)
        }
      end)
      |> Enum.sort_by(& &1["uri"])

    %{
      "uri" => "skill://#{skill_name}/SKILL.md",
      "frontmatter" => frontmatter,
      "resources" => files
    }
  rescue
    _ -> nil
  end

  defp list_files_recursive(dir) do
    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.filter(&File.regular?/1)
  end

  defp parse_frontmatter(text, fallback_name) do
    case Regex.run(~r/\A---\s*\n(.*?)\n---\s*\n?(.*)\z/s, text) do
      [_, yaml, body] ->
        fm = %{
          "name" => yaml_value(yaml, "name") || fallback_name,
          "description" => yaml_value(yaml, "description") || ""
        }
        {fm, body}

      _ ->
        {%{"name" => fallback_name, "description" => ""}, text}
    end
  end

  defp yaml_value(yaml, key) do
    case Regex.run(~r/^\s*#{Regex.escape(key)}\s*:\s*(.+)\s*$/m, yaml) do
      [_, value] -> String.trim(value, "\"'")
      _ -> nil
    end
  end

  defp uri_to_path("skill://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [skill_name, rel] ->
        base = Path.expand(skills_dir())
        path = Path.expand(Path.join([base, skill_name, rel]))
        if String.starts_with?(path, base <> "/") or path == base, do: {:ok, skill_name, path}, else: :error
      _ -> :error
    end
  end
  defp uri_to_path(_), do: :error

  def skill_name_from_uri("skill://" <> rest), do: rest |> String.split("/", parts: 2) |> hd()
  def skill_name_from_uri(_), do: nil

  defp mime_type(path) do
    case Path.extname(path) do
      ".md" -> "text/markdown"
      ".txt" -> "text/plain"
      ".json" -> "application/json"
      ".yaml" -> "text/yaml"
      ".yml" -> "text/yaml"
      _ -> "application/octet-stream"
    end
  end

  defp text_result(text) do
    %{"content" => [%{"type" => "text", "text" => text}]}
  end
end

defmodule McpGateway.Skills do
  @moduledoc """
  URI namespacing for the io.modelcontextprotocol/skills extension (SEP-2640).

  A skill is identified by its originating server plus its URI, and URIs are
  how manifests, approvals, and caches bind. Aggregating several servers behind
  one endpoint would collide identical URIs, so the gateway rewrites the
  authority segment to `<server>__<skill>` and reverses the rewrite on the way
  upstream. Digests and sizes cover content, which passes through unchanged,
  so they never need recomputing.
  """

  @extension "io.modelcontextprotocol/skills"
  @scheme "skill://"

  def extension, do: @extension

  # True when an upstream initialize response declared the skills extension.
  def declared?(response) do
    get_in(response, ["result", "capabilities", "extensions", @extension]) != nil
  end

  def namespace(server, %{"uri" => uri} = skill) do
    skill =
      skill
      |> Map.put("uri", prefix_uri(server, uri))
      |> update_in(["frontmatter", "name"], fn name -> "#{server}__#{name}" end)

    case skill["resources"] do
      list when is_list(list) ->
        %{skill | "resources" => Enum.map(list, &namespace_file(server, &1))}

      _ ->
        skill
    end
  end

  def namespace_content(server, %{"uri" => uri} = content) when is_binary(uri) do
    Map.put(content, "uri", prefix_uri(server, uri))
  end

  def namespace_content(_server, content), do: content

  # skill://<server>__<name>/path -> {server, skill://<name>/path}
  def denamespace(@scheme <> rest) do
    with [authority | path] <- String.split(rest, "/", parts: 2),
         [server, name] <- String.split(authority, "__", parts: 2) do
      {:ok, server, @scheme <> name <> "/" <> Enum.join(path, "/")}
    else
      _ -> :error
    end
  end

  def denamespace(_uri), do: :error

  defp namespace_file(server, %{"uri" => uri} = file) when is_binary(uri) do
    Map.put(file, "uri", prefix_uri(server, uri))
  end

  defp namespace_file(_server, file), do: file

  defp prefix_uri(server, @scheme <> rest), do: @scheme <> server <> "__" <> rest
  defp prefix_uri(_server, uri), do: uri
end

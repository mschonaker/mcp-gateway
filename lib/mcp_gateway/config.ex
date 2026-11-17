defmodule McpGateway.Config do
  @moduledoc false

  def port, do: Application.get_env(:mcp_gateway, :port, 4000)
  def base_url, do: Application.get_env(:mcp_gateway, :base_url, "http://localhost:#{port()}")
  def skills_dir, do: Application.get_env(:mcp_gateway, :skills_dir, Path.expand("../../skills", __DIR__))
  def allowlist_path, do: Application.get_env(:mcp_gateway, :allowlist_path, Path.expand("../../config/allowlist.txt", __DIR__))

  def google_client_id, do: Application.get_env(:mcp_gateway, :google_client_id)
  def google_client_secret, do: Application.get_env(:mcp_gateway, :google_client_secret)

  def load_allowlist do
    path = allowlist_path()

    case File.read(path) do
      {:ok, data} ->
        data
        |> String.split(~r/\R/, trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end
end

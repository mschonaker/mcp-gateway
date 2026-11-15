defmodule McpGateway.Application do
  use Application
  require Logger

  alias McpGateway.Upstream

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: McpGateway.Upstreams},
      McpGateway.Sessions,
      {DynamicSupervisor,
       name: McpGateway.UpstreamSupervisor,
       strategy: :one_for_one,
       max_restarts: 10,
       max_seconds: 5},
      {Bandit, plug: McpGateway.Router, port: Application.fetch_env!(:mcp_gateway, :port)}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: McpGateway.Supervisor) do
      {:ok, supervisor} ->
        start_configured_upstreams()
        {:ok, supervisor}

      error ->
        error
    end
  end

  defp start_configured_upstreams do
    for cfg <- Application.fetch_env!(:mcp_gateway, :upstreams) do
      opts = [name: cfg["name"], command: cfg["command"], args: cfg["args"] || []]

      case DynamicSupervisor.start_child(McpGateway.UpstreamSupervisor, {Upstream, opts}) do
        {:ok, _pid} -> :ok
        {:error, reason} -> Logger.error("[#{cfg["name"]}] failed to start: #{inspect(reason)}")
      end
    end
  end
end

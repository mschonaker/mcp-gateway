defmodule McpGateway.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: McpGateway.Finch},
      McpGateway.Store,
      {Bandit, plug: McpGateway.Router, port: McpGateway.Config.port()}
    ]

    opts = [strategy: :one_for_one, name: McpGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

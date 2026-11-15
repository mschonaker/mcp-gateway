import Config

config :mcp_gateway,
  port: 4000,
  require_session: true,
  upstreams: []

config :logger, :console, format: "[$level] $message\n"

import_config "#{config_env()}.exs"

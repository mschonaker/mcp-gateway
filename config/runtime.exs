import Config

if json = System.get_env("MCP_UPSTREAMS") do
  config :mcp_gateway, :upstreams, Jason.decode!(json)
end

if port = System.get_env("PORT") do
  config :mcp_gateway, :port, String.to_integer(port)
end

import Config

if port = System.get_env("PORT") do
  config :mcp_gateway, :port, String.to_integer(port)
end

if base_url = System.get_env("BASE_URL") do
  config :mcp_gateway, :base_url, base_url
end

if skills_dir = System.get_env("SKILLS_DIR") do
  config :mcp_gateway, :skills_dir, skills_dir
end

if allowlist = System.get_env("ALLOWLIST_PATH") do
  config :mcp_gateway, :allowlist_path, allowlist
end

if client_id = System.get_env("GOOGLE_CLIENT_ID") do
  config :mcp_gateway, :google_client_id, client_id
end

if client_secret = System.get_env("GOOGLE_CLIENT_SECRET") do
  config :mcp_gateway, :google_client_secret, client_secret
end

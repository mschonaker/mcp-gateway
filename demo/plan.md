# Demo plan

1. The gateway aggregates two upstream MCP servers behind one URL.
2. demo  -> @modelcontextprotocol/server-filesystem, scoped to ./demo
3. echo  -> the Elixir echo upstream from priv/fake_mcp_server.exs
4. OpenCode calls namespaced tools like demo__read_text_file.

defmodule McpGateway.Store do
  @moduledoc """
  In-memory runtime state. Everything is lost on restart.
  """
  use GenServer

  @table __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    :ets.insert(table, {:allowlist, McpGateway.Config.load_allowlist()})
    :ets.insert(table, {:web_sessions, %{}})
    :ets.insert(table, {:mcp_tokens, %{}})
    :ets.insert(table, {:oauth_states, %{}})
    :ets.insert(table, {:upstreams, %{}})
    :ets.insert(table, {:upstream_oauth_states, %{}})
    :ets.insert(table, {:policy, %{}})
    :ets.insert(table, {:tool_cache, %{}})
    {:ok, %{table: table}}
  end

  # Allowlist
  def allowlisted?(email) when is_binary(email) do
    case :ets.lookup(@table, :allowlist) do
      [{:allowlist, set}] -> MapSet.member?(set, String.downcase(email))
      _ -> false
    end
  end

  # Web sessions: session_id => %{email: ..., created_at: ...}
  def put_web_session(id, data), do: update_map(:web_sessions, &Map.put(&1, id, data))
  def get_web_session(id), do: get_map(:web_sessions)[id]
  def delete_web_session(id), do: update_map(:web_sessions, &Map.delete(&1, id))

  # MCP bearer tokens: token => %{email: ..., session_id: ...}
  def put_mcp_token(token, data), do: update_map(:mcp_tokens, &Map.put(&1, token, data))
  def get_mcp_token(token), do: get_map(:mcp_tokens)[token]
  def delete_mcp_token(token), do: update_map(:mcp_tokens, &Map.delete(&1, token))

  # Login OAuth states: state => %{return_to: ..., inserted_at: ...}
  def put_oauth_state(state, data), do: update_map(:oauth_states, &Map.put(&1, state, data))
  def pop_oauth_state(state) do
    data = get_map(:oauth_states)[state]
    update_map(:oauth_states, &Map.delete(&1, state))
    data
  end

  # Upstreams: name => %{name, url, auth: %{type: "none"|"bearer"|"oauth", ...}, tools: [...], status: ...}
  def put_upstream(name, data), do: update_map(:upstreams, &Map.put(&1, name, data))
  def get_upstream(name), do: get_map(:upstreams)[name]
  def list_upstreams, do: get_map(:upstreams) |> Map.values() |> Enum.sort_by(& &1.name)
  def delete_upstream(name) do
    update_map(:upstreams, &Map.delete(&1, name))
    update_map(:tool_cache, &Map.delete(&1, name))
    update_map(:policy, &Map.delete(&1, name))
  end

  # Upstream OAuth pending states: state => %{upstream: name, inserted_at: ...}
  def put_upstream_oauth_state(state, data), do: update_map(:upstream_oauth_states, &Map.put(&1, state, data))
  def pop_upstream_oauth_state(state) do
    data = get_map(:upstream_oauth_states)[state]
    update_map(:upstream_oauth_states, &Map.delete(&1, state))
    data
  end

  # Policy: %{upstream_name => %{tool_name => boolean}} default true when missing
  def allowed?(upstream, tool) do
    case get_map(:policy) do
      %{^upstream => %{^tool => value}} -> value
      _ -> true
    end
  end

  def set_allowed(upstream, tool, value) when is_boolean(value) do
    update_map(:policy, fn policy ->
      up = Map.get(policy, upstream, %{})
      Map.put(policy, upstream, Map.put(up, tool, value))
    end)
  end

  def policy_for(upstream), do: get_map(:policy)[upstream] || %{}

  # Tool cache: %{upstream => [tool_maps]}
  def put_tools(upstream, tools), do: update_map(:tool_cache, &Map.put(&1, upstream, tools || []))
  def get_tools(upstream), do: get_map(:tool_cache)[upstream] || []
  def all_tools do
    get_map(:tool_cache)
    |> Enum.flat_map(fn {upstream, tools} -> Enum.map(tools, &{upstream, &1}) end)
  end

  defp get_map(key) do
    case :ets.lookup(@table, key) do
      [{^key, map}] when is_map(map) -> map
      _ -> %{}
    end
  end

  defp update_map(key, fun) do
    :ets.insert(@table, {key, fun.(get_map(key))})
    :ok
  end
end

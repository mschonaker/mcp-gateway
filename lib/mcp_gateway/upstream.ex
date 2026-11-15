defmodule McpGateway.Upstream do
  @moduledoc """
  GenServer that owns one stdio MCP server process.

  Spawns the server via a line-delimited Port, performs the MCP handshake,
  caches its (namespaced) tool list, and forwards tools/call requests.
  Requests that arrive before the handshake completes are queued, so cold
  starts like `npx -y ...` do not surface as errors.
  """
  use GenServer
  require Logger

  @protocol_version "2025-03-26"
  @client_info %{"name" => "elixir-mcp-gateway", "version" => "0.1.0"}
  @call_timeout 30_000

  defstruct [:name, :port, :next_id, :tools, pending: %{}, queued: []]

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def child_spec(opts) do
    %{id: {:upstream, Keyword.fetch!(opts, :name)}, start: {__MODULE__, :start_link, [opts]}}
  end

  def via(name) do
    {:via, Registry, {McpGateway.Upstreams, name}}
  end

  def list_tools(name) do
    GenServer.call(via(name), :list_tools, @call_timeout)
  end

  def call_tool(name, tool, arguments) do
    GenServer.call(via(name), {:call_tool, tool, arguments}, @call_timeout)
  end

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    executable = System.find_executable(command) || raise "executable not found: #{command}"

    port =
      Port.open(
        {:spawn, Enum.map_join([executable | args], " ", &inspect/1)},
        port_options()
      )

    send(self(), :initialize)
    {:ok, %__MODULE__{name: Keyword.fetch!(opts, :name), port: port, next_id: 1}}
  end

  # A release prepends its erts and bin directories to PATH. Child processes
  # must not see them, or toolchain binaries such as erl and escript resolve
  # to the release shims instead of the real ones.
  defp port_options do
    case System.get_env("RELEASE_ROOT") do
      nil -> [:binary, :exit_status, {:line, 1_048_576}]
      release_root -> [{:env, child_env(release_root)}, :binary, :exit_status, {:line, 1_048_576}]
    end
  end

  defp child_env(release_root) do
    child_path =
      System.get_env("PATH", "")
      |> String.split(":")
      |> Enum.reject(&String.starts_with?(&1, release_root <> "/"))
      |> Enum.join(":")

    env = [{"PATH", child_path} | Enum.to_list(Map.delete(System.get_env(), "PATH"))]

    for {key, value} <- env do
      {String.to_charlist(key), String.to_charlist(value)}
    end
  end

  @impl true
  def handle_info(:initialize, state) do
    params = %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => @client_info
    }

    {:noreply, request(state, "initialize", params, :handshake)}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, message} ->
        handle_message(message, state)

      {:error, _} ->
        Logger.warning("[#{state.name}] non-JSON line: #{line}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:noeol, partial}}}, %{port: port} = state) do
    Logger.warning("[#{state.name}] oversized line truncated: #{partial}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:upstream_exit, status}, state}
  end

  @impl true
  def handle_call(:list_tools, from, %{tools: nil} = state) do
    {:noreply, %{state | queued: state.queued ++ [{:list, from}]}}
  end

  def handle_call(:list_tools, _from, state) do
    {:reply, state.tools, state}
  end

  def handle_call({:call_tool, tool, arguments}, from, %{tools: nil} = state) do
    {:noreply, %{state | queued: state.queued ++ [{:call, tool, arguments, from}]}}
  end

  def handle_call({:call_tool, tool, arguments}, from, state) do
    params = %{"name" => tool, "arguments" => arguments}
    {:noreply, request(state, "tools/call", params, from)}
  end

  # A message with both "id" and "method" is a server-initiated request.
  # The gateway does not support server-initiated methods, so reject them.
  defp handle_message(%{"id" => id, "method" => method}, state) do
    Logger.info("[#{state.name}] unsupported server request: #{method}")

    error = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Method not found"}
    }

    write(state.port, error)
    {:noreply, state}
  end

  defp handle_message(%{"id" => id} = response, state) do
    handle_response(id, response, state)
  end

  defp handle_message(%{"method" => "notifications/tools/list_changed"}, state) do
    {:noreply, request(state, "tools/list", %{}, :fetch_tools)}
  end

  defp handle_message(%{"method" => "notifications/" <> _}, state) do
    {:noreply, state}
  end

  defp handle_message(other, state) do
    Logger.warning("[#{state.name}] unexpected message: #{inspect(other)}")
    {:noreply, state}
  end

  defp handle_response(id, response, state) do
    case Map.pop(state.pending, id) do
      {:handshake, pending} ->
        state = %{state | pending: pending}
        write(state.port, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
        {:noreply, request(state, "tools/list", %{}, :fetch_tools)}

      {:fetch_tools, pending} ->
        tools =
          (get_in(response, ["result", "tools"]) || [])
          |> Enum.map(&Map.put(&1, "name", tool_key(state.name, &1["name"])))

        Logger.info("[#{state.name}] loaded #{length(tools)} tools")
        state = %{state | tools: tools, pending: pending}
        {:noreply, flush_queue(state)}

      {from, pending} when is_tuple(from) ->
        GenServer.reply(from, {:ok, response})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  defp request(state, method, params, tag) do
    message = %{"jsonrpc" => "2.0", "id" => state.next_id, "method" => method, "params" => params}
    write(state.port, message)
    %{state | next_id: state.next_id + 1, pending: Map.put(state.pending, state.next_id, tag)}
  end

  defp flush_queue(%{queued: []} = state), do: state

  defp flush_queue(state) do
    state =
      Enum.reduce(state.queued, state, fn
        {:list, from}, acc ->
          GenServer.reply(from, acc.tools)
          acc

        {:call, tool, arguments, from}, acc ->
          request(acc, "tools/call", %{"name" => tool, "arguments" => arguments}, from)
      end)

    %{state | queued: []}
  end

  defp tool_key(server, tool), do: "#{server}__#{tool}"

  defp write(port, payload) do
    Port.command(port, Jason.encode!(payload) <> "\n")
  end
end

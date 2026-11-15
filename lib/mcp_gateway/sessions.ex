defmodule McpGateway.Sessions do
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)
  end

  def create do
    session_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64()
    Agent.update(__MODULE__, &MapSet.put(&1, session_id))
    session_id
  end

  def known?(session_id) do
    Agent.get(__MODULE__, &MapSet.member?(&1, session_id))
  end

  def delete(session_id) do
    Agent.update(__MODULE__, &MapSet.delete(&1, session_id))
  end
end

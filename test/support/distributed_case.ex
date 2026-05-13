defmodule Minga.Test.DistributedCase do
  @moduledoc "Helpers for tests that exercise Erlang distribution."

  use ExUnit.CaseTemplate

  using do
    quote do
      import Minga.Test.DistributedCase
    end
  end

  setup do
    ensure_local_node()
    :ok
  end

  @doc "Ensures the current test VM is a distributed node."
  @spec ensure_local_node() :: :ok
  def ensure_local_node do
    if Node.alive?() do
      :ok
    else
      name = :"minga_test_#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _pid} = Node.start(name, :longnames)
      :ok
    end
  end

  @doc "Starts a peer node with the current code path loaded."
  @spec start_peer_node(atom()) :: {:ok, %{peer_pid: pid(), node: node()}}
  def start_peer_node(name) when is_atom(name) do
    {:ok, pid, node} = :peer.start(%{name: name, connection: :standard_io})
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    {:ok, %{peer_pid: pid, node: node}}
  end

  @doc "Stops a peer node started by `start_peer_node/1`."
  @spec stop_peer_node(%{peer_pid: pid()}) :: :ok
  def stop_peer_node(%{peer_pid: pid}) do
    :peer.stop(pid)
  end
end

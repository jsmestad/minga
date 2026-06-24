defmodule Minga.TestExtensions.ConcurrentDoubleStart do
  @moduledoc "Test extension for lifecycle double-start synchronization."

  use Minga.Extension

  option(:test_pid, :any,
    default: nil,
    description: "Test process notified when init starts"
  )

  command(:concurrent_double_start_cmd, "Concurrent double start command",
    execute: {__MODULE__, :noop}
  )

  @impl true
  @spec name() :: :concurrent_double_start
  def name, do: :concurrent_double_start

  @impl true
  @spec description() :: String.t()
  def description, do: "Concurrent double start"

  @impl true
  @spec version() :: String.t()
  def version, do: "1.0.0"

  @impl true
  @spec init(keyword()) :: {:ok, map()} | {:error, atom()}
  def init(config) do
    test_pid = Keyword.fetch!(config, :test_pid)
    send(test_pid, {:concurrent_double_start_init_entered, self()})

    receive do
      :release_concurrent_double_start_init -> {:ok, %{}}
    after
      5_000 -> {:error, :concurrent_double_start_timeout}
    end
  end

  @spec noop(map()) :: map()
  def noop(state), do: state
end

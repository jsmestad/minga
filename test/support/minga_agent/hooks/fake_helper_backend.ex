defmodule MingaAgent.Hooks.FakeHelperBackend do
  @moduledoc false

  @behaviour MingaAgent.Hooks.CommandRunner.HelperBackend

  @enforce_keys [:id, :observer, :events]
  defstruct [:id, :observer, :events]

  @type event :: {:data, binary()} | {:exit_status, non_neg_integer()}
  @type t :: %__MODULE__{id: reference(), observer: pid(), events: [event()] | :repeat_data}

  @impl true
  @spec start(String.t(), [String.t()], String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(_helper_path, args, payload_json, opts) do
    observer = Keyword.fetch!(opts, :observer)
    events = Keyword.fetch!(opts, :events)
    id = make_ref()
    send(observer, {:fake_helper, id, :started, args, payload_json})
    {:ok, %__MODULE__{id: id, observer: observer, events: events}}
  end

  @impl true
  @spec next_event(t(), non_neg_integer()) :: MingaAgent.Hooks.CommandRunner.HelperBackend.event()
  def next_event(%__MODULE__{events: :repeat_data} = handle, _timeout_ms) do
    {:data, "x", handle}
  end

  def next_event(%__MODULE__{events: [{:data, data} | rest]} = handle, _timeout_ms) do
    next_handle = %{handle | events: rest}
    {:data, data, next_handle}
  end

  def next_event(%__MODULE__{events: [{:exit_status, status} | rest]} = handle, _timeout_ms) do
    next_handle = %{handle | events: rest}
    {:exit_status, status, next_handle}
  end

  def next_event(%__MODULE__{events: []}, _timeout_ms), do: :timeout

  @impl true
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{id: id, observer: observer}) do
    send(observer, {:fake_helper, id, :stopped})
    :ok
  end
end

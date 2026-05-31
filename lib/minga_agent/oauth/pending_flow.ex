defmodule MingaAgent.OAuth.PendingFlow do
  @moduledoc """
  Stores short-lived manual OAuth flows on the server.

  The PKCE verifier stays in this process. Clients only receive the authorize URL and opaque ref, then paste back the single-use authorization result so the server can exchange it.
  """

  use GenServer

  @type ref :: String.t()
  alias MingaAgent.OAuth.PendingFlow.Entry

  @type flow :: Entry.t()
  @type entry :: %{flow: flow() | nil, timer: reference() | nil, expired?: boolean()}
  @type state :: %{optional(ref()) => entry()}

  @max_pending_flows 32
  @expired_tombstone_ms 60_000

  @doc "Starts the pending-flow store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc "Stores a pending OAuth flow and returns its opaque ref."
  @spec put(flow(), pos_integer()) :: {:ok, ref()} | {:error, term()}
  def put(%Entry{} = flow, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, _pid} <- ensure_started() do
      GenServer.call(__MODULE__, {:put, flow, timeout_ms})
    end
  end

  @doc "Consumes a pending OAuth flow by ref."
  @spec take(ref()) :: {:ok, flow()} | {:error, :unknown_flow | :expired_flow | term()}
  def take(ref) when is_binary(ref) do
    with {:ok, _pid} <- ensure_started() do
      GenServer.call(__MODULE__, {:take, ref})
    end
  end

  @doc false
  @spec expire(ref()) :: :ok | {:error, term()}
  def expire(ref) when is_binary(ref) do
    with {:ok, _pid} <- ensure_started() do
      GenServer.call(__MODULE__, {:expire, ref})
    end
  end

  @impl GenServer
  @spec init(state()) :: {:ok, state()}
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:put, %Entry{} = flow, timeout_ms}, _from, state) do
    if active_count(state) >= @max_pending_flows do
      {:reply, {:error, :too_many_pending_flows}, state}
    else
      ref = new_ref()
      timer = Process.send_after(self(), {:expire, ref}, timeout_ms)
      entry = %{flow: flow, timer: timer, expired?: false}
      {:reply, {:ok, ref}, Map.put(state, ref, entry)}
    end
  end

  def handle_call({:take, ref}, _from, state) do
    {entry, state} = Map.pop(state, ref)
    {reply, state} = take_reply(entry, state)
    {:reply, reply, state}
  end

  def handle_call({:expire, ref}, _from, state) do
    {:reply, :ok, expire_ref(state, ref)}
  end

  @impl GenServer
  def handle_info({:expire, ref}, state) do
    {:noreply, expire_ref(state, ref)}
  end

  def handle_info({:purge, ref}, state) do
    {:noreply, Map.delete(state, ref)}
  end

  @spec ensure_started() :: {:ok, pid()} | {:error, term()}
  defp ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start_or_reuse()
    end
  end

  @spec start_or_reuse() :: {:ok, pid()} | {:error, term()}
  defp start_or_reuse do
    case start_link() do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec take_reply(entry() | nil, state()) ::
          {{:ok, flow()} | {:error, :unknown_flow | :expired_flow}, state()}
  defp take_reply(nil, state), do: {{:error, :unknown_flow}, state}

  defp take_reply(%{expired?: true}, state), do: {{:error, :expired_flow}, state}

  defp take_reply(%{flow: flow, timer: timer}, state) when is_map(flow) and is_reference(timer) do
    Process.cancel_timer(timer)
    {{:ok, flow}, state}
  end

  @spec expire_ref(state(), ref()) :: state()
  defp expire_ref(state, ref) do
    state =
      state
      |> Map.update(ref, nil, &expire_entry/1)
      |> drop_nil_entry(ref)

    Process.send_after(self(), {:purge, ref}, @expired_tombstone_ms)
    state
  end

  @spec expire_entry(entry() | nil) :: entry() | nil
  defp expire_entry(nil), do: nil

  defp expire_entry(entry) do
    %{entry | flow: nil, timer: nil, expired?: true}
  end

  @spec active_count(state()) :: non_neg_integer()
  defp active_count(state) do
    Enum.count(state, fn {_ref, entry} -> entry.flow != nil and not entry.expired? end)
  end

  @spec drop_nil_entry(state(), ref()) :: state()
  defp drop_nil_entry(state, ref) do
    case Map.fetch(state, ref) do
      {:ok, nil} -> Map.delete(state, ref)
      _other -> state
    end
  end

  @spec new_ref() :: ref()
  defp new_ref do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end
end

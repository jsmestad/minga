defmodule MingaAgent.OAuth.PendingFlow do
  @moduledoc """
  Stores short-lived manual OAuth flows on the server.

  The PKCE verifier stays in this process. Clients only receive the authorize URL and opaque ref, then paste back the single-use authorization result so the server can exchange it.
  """

  use GenServer

  @type ref :: String.t()
  alias MingaAgent.OAuth.PendingFlow.Entry

  @type flow :: Entry.t()
  @typep owner :: {String.t() | nil, pid() | nil}
  @type writer :: (MingaAgent.OAuth.token_response() -> :ok | {:error, term()})
  @type completion :: {flow(), writer() | nil, reference() | nil}
  @type entry :: %{
          completion: completion() | nil,
          timer: reference() | nil,
          worker: {pid(), reference()} | nil
        }
  @type state :: %{optional(ref()) => entry()}

  @max_pending_flows 32
  @expired_tombstone_ms 60_000

  @doc "Starts the pending-flow store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc "Stores a pending flow with its exact writer and operation reference."
  @spec put(flow(), pos_integer(), keyword()) :: {:ok, ref()} | {:error, term()}
  def put(%Entry{} = flow, timeout_ms, opts \\ [])
      when is_integer(timeout_ms) and timeout_ms > 0 do
    completion = {flow, Keyword.get(opts, :write_fun), Keyword.get(opts, :operation_ref)}

    with {:ok, _pid} <- ensure_started() do
      GenServer.call(__MODULE__, {:put, completion, timeout_ms})
    end
  end

  @doc "Consumes a pending OAuth flow only for its owner, or for standalone login."
  @spec take(ref(), keyword()) :: {:ok, completion()} | {:error, term()}
  def take(ref, opts \\ []) when is_binary(ref) do
    owner = {Keyword.get(opts, :session_id), Keyword.get(opts, :client_pid)}

    with {:ok, _pid} <- ensure_started() do
      GenServer.call(__MODULE__, {:take, ref, owner, Keyword.get(opts, :operation_ref)})
    end
  end

  @doc "Requests retirement of matching operation-and-owner material without invoking its writer."
  @spec cancel_operation(reference(), owner()) :: :ok
  def cancel_operation(operation_ref, owner) when is_reference(operation_ref) do
    GenServer.cast(__MODULE__, {:cancel_operation, operation_ref, owner})
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
  def handle_call({:put, completion, timeout_ms}, {caller, _}, state) do
    if active_count(state) >= @max_pending_flows do
      {:reply, {:error, :too_many_pending_flows}, state}
    else
      ref = new_ref()
      timer = Process.send_after(self(), {:expire, ref}, timeout_ms)
      {_, _, operation_ref} = completion
      worker = monitor_worker(operation_ref, caller)
      entry = %{completion: completion, timer: timer, worker: worker}
      {:reply, {:ok, ref}, Map.put(state, ref, entry)}
    end
  end

  def handle_call({:take, ref, owner, operation_ref}, {caller, _tag}, state) do
    entry = Map.get(state, ref)

    {reply, state} =
      case entry do
        %{worker: {worker, _monitor}} when caller != worker ->
          {{:error, :wrong_worker}, state}

        _unbound_or_owned ->
          take_reply(entry, ref, owner, operation_ref, state)
      end

    {:reply, reply, state}
  end

  def handle_call({:expire, ref}, _from, state) do
    {:reply, :ok, expire_ref(state, ref)}
  end

  @impl GenServer
  def handle_cast({:cancel_operation, ref, owner}, state) do
    remaining =
      retire_matching(state, fn
        %{completion: {%Entry{owner_session_id: id, owner_client_pid: pid}, _, ^ref}} ->
          owner == {id, pid}

        _other ->
          false
      end)

    {:noreply, remaining}
  end

  @impl GenServer
  def handle_info({:expire, ref}, state) do
    {:noreply, expire_ref(state, ref)}
  end

  def handle_info({:purge, ref}, state) do
    {:noreply, Map.delete(state, ref)}
  end

  def handle_info({:DOWN, monitor, :process, worker, _reason}, state) do
    {:noreply, retire_matching(state, &(&1.worker == {worker, monitor}))}
  end

  @impl GenServer
  @spec format_status(map()) :: map()
  def format_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :log, :reason] -> {key, :redacted}
      pair -> pair
    end)
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

  @spec take_reply(entry() | nil, ref(), owner(), reference() | nil, state()) ::
          {{:ok, completion()} | {:error, term()}, state()}
  defp take_reply(nil, _ref, _owner, _operation_ref, state),
    do: {{:error, :unknown_flow}, state}

  defp take_reply(%{completion: nil}, ref, _owner, _operation_ref, state),
    do: {{:error, :expired_flow}, Map.delete(state, ref)}

  defp take_reply(%{completion: {flow, _, bound_ref}} = entry, ref, owner, operation_ref, state) do
    with :ok <- authorize_owner(flow, owner),
         :ok <- authorize_operation(bound_ref, operation_ref) do
      retire_entry(entry)
      {{:ok, entry.completion}, Map.delete(state, ref)}
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  @spec authorize_owner(flow(), owner()) :: :ok | {:error, :wrong_owner}
  defp authorize_owner(flow, owner) do
    if owned_by?(flow, owner), do: :ok, else: {:error, :wrong_owner}
  end

  @spec authorize_operation(reference() | nil, reference() | nil) ::
          :ok | {:error, :wrong_operation}
  defp authorize_operation(nil, nil), do: :ok
  defp authorize_operation(ref, ref) when is_reference(ref), do: :ok
  defp authorize_operation(_bound, _provided), do: {:error, :wrong_operation}

  @spec monitor_worker(reference() | nil, pid()) :: {pid(), reference()} | nil
  defp monitor_worker(nil, _pid), do: nil
  defp monitor_worker(ref, pid) when is_reference(ref), do: {pid, Process.monitor(pid)}

  @spec retire_entry(entry()) :: :ok
  defp retire_entry(%{completion: nil}), do: :ok

  defp retire_entry(entry) do
    Process.cancel_timer(entry.timer)

    case entry.worker do
      {_pid, monitor} -> Process.demonitor(monitor, [:flush])
      nil -> :ok
    end

    :ok
  end

  @spec retire_matching(state(), (entry() -> boolean())) :: state()
  defp retire_matching(state, matches?) do
    Enum.reduce(state, state, fn {ref, entry}, remaining ->
      if matches?.(entry) do
        retire_entry(entry)
        Map.delete(remaining, ref)
      else
        remaining
      end
    end)
  end

  @spec owned_by?(flow(), owner()) :: boolean()
  defp owned_by?(%Entry{owner_session_id: nil, owner_client_pid: nil}, _owner), do: true
  defp owned_by?(%Entry{owner_session_id: id, owner_client_pid: pid}, {id, pid}), do: true
  defp owned_by?(%Entry{}, _owner), do: false

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
    retire_entry(entry)
    %{entry | completion: nil, timer: nil, worker: nil}
  end

  @spec active_count(state()) :: non_neg_integer()
  defp active_count(state) do
    Enum.count(state, fn {_ref, entry} -> entry.completion != nil end)
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
